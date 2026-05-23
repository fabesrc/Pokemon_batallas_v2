defmodule PokemonBattle.Servidor do
  alias PokemonBattle.{
    GestorEntrenadores, GestorSalas, SistemaSobres, Cluster
  }

  # Estado de la sesion actual del jugador
  defstruct [
    user: nil,
    sala: nil,
    batalla: nil,
    trade: nil,
    esperando_cambio: false  # control de flujo
  ]

  def iniciar_sesion do
    IO.puts("\n--- POKÉMON BATTLE ARENA ---")
    IO.puts("Nodo actual: #{node()}")
    IO.puts("Escribe 'ayuda' para ver comandos.")

    loop(%__MODULE__{})
  end

  defp loop(state) do
    # Revisar si hay mensajes de otros procesos (eventos)
    state = revisar_buzon(state)
    prompt = if state.user do
      t = GestorEntrenadores.obtener(state.user)
      "#{state.user}(#{t.monedas_actuales})> "
    else
      "(sin login)> "
    end

    input = IO.gets(prompt) |> String.trim()

    case procesar(input, state) do
      {:ok, nuevo_estado} -> loop(nuevo_estado)
      {:error, msg, s} ->
        IO.puts("Error: #{msg}")
        loop(s)
      :salir -> IO.puts("¡Chao!")
    end
  end

  # Manejo de mensajes asincronos
  defp revisar_buzon(state) do
    receive do
      {:batalla_evento, "Esperando cambios de pokemon..." <> _} ->
        IO.puts("\n[BATALLA] ¡Tu Pokémon se debilitó! Debes cambiarlo.")
        revisar_buzon(%{state | esperando_cambio: true})

      {:batalla_evento, "Turno " <> _} ->
        revisar_buzon(%{state | esperando_cambio: false})

      {:batalla_evento, msg} ->
        IO.puts("\n[BATALLA] #{msg}")
        revisar_buzon(state)

      {:batalla_terminada, %{ganador: g}} ->
        IO.puts("\n*** BATALLA TERMINADA. GANÓ: #{g} ***")
        %{state | batalla: nil, sala: nil, esperando_cambio: false}

      {:intercambio_evento, msg} ->
        IO.puts("\n[TRADE] #{msg}")
        revisar_buzon(state)

      {:intercambio_completado, _} ->
        IO.puts("\n Intercambio finalizado con éxito.")
        %{state | trade: nil}

    after
      0 -> state
    end
  end

  # Procesar Comandos
  defp procesar("", s), do: {:ok, s}
  defp procesar("salir", _), do: :salir
  defp procesar("ayuda", s), do: mostrar_ayuda(s)

  defp procesar(input, state) do
    input = if (state.batalla || state.sala) && Regex.match?(~r/^\d+$/, input) do
      "atacar #{input}"
    else
      input
    end

    [cmd | args] = String.split(input, " ")
    ejecutar(cmd, args, state)
  end

  # Lógica de Comandos

  defp ejecutar("crear_equipo", [nombre | resto], s) do

    ids = Enum.join(resto, "")
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.to_integer/1)

    case GestorEntrenadores.crear_equipo(s.user, nombre, ids) do
      :ok ->
        IO.puts("¡Equipo '#{nombre}' guardado con éxito!")
        {:ok, s}
      {:error, e} ->
        {:error, e, s}
    end
  end

  # Login
  defp ejecutar("login", [u, p], s) do
    case GestorEntrenadores.iniciar_sesion(u, p) do
      {:ok, _, _} ->
        IO.puts("Hola #{u}!")
        {:ok, %{s | user: u}}
      {:error, e} -> {:error, e, s}
    end
  end

  defp ejecutar(_, _, %{user: nil} = s), do: {:error, "Haz login primero", s}

  # Perfil e Inventario
  defp ejecutar("perfil", _, s) do
    t = GestorEntrenadores.obtener(s.user)
    IO.puts("\n--- PERFIL DE #{s.user} ---")
    IO.puts("Victorias: #{t.victorias} | Monedas: #{t.monedas_actuales}")
    IO.puts("Pokémon: #{length(t.inventario)}")
    {:ok, s}
  end

  defp ejecutar("inventario", _, s) do
    t = GestorEntrenadores.obtener(s.user)
    IO.puts("\n--- TU MOCHILA ---")
    Enum.each(t.inventario, fn p ->
      IO.puts("##{p.id} #{p.especie} (Atk:#{p.ataque} Def:#{p.defensa})")
    end)
    {:ok, s}
  end

  # Tienda
  defp ejecutar("comprar", [tipo], s) do
    case SistemaSobres.comprar_sobre(s.user, tipo) do
      {:ok, _} -> IO.puts("Sobre comprado!"); {:ok, s}
      {:error, e} -> {:error, e, s}
    end
  end

  defp ejecutar("abrir", _, s) do
    case SistemaSobres.abrir_sobre(s.user, "ultimo") do
      {:ok, pokes} ->
        IO.puts("¡Te salieron!")
        Enum.each(pokes, &IO.puts("- #{&1.especie}"))
        {:ok, s}
      {:error, e} -> {:error, e, s}
    end
  end

  # Batallas

  defp ejecutar("conectar_nodo", [nombre], s) do
    case Cluster.conectar(nombre) do
      {:ok, msg} ->
        IO.puts(msg)
        {:ok, s}
      {:error, e} ->
        {:error, e, s}
    end
  end

  defp ejecutar("crear_sala", [equipo], s) do
    case GestorSalas.crear_sala(s.user, equipo) do
      {:ok, id} ->
        IO.puts("Sala #{id} creada.");
        {:ok, %{s | sala: id, batalla: id}}
      {:error, e} -> {:error, e, s}
    end
  end

  defp ejecutar("unirse", args, s) when length(args) >= 2 do
    equipo = List.last(args)
    id = args |> Enum.slice(0..-2//1) |> Enum.join(" ")

    case GestorSalas.unirse_sala(id, s.user, equipo) do
      {:ok, _} ->
        IO.puts("¡Te has unido a la sala #{id}!")
        {:ok, %{s | batalla: id}}
      {:error, e} ->
        {:error, e, s}
    end
  end

  defp ejecutar("atacar", [n], s) do
    cond do
      is_nil(s.batalla) ->
        {:error, "No estás en una batalla activa", s}

      s.esperando_cambio ->
        {:error, "Tu Pokémon está debilitado, debes usar el comando 'cambiar <id_pkm>' primero", s}

      true ->
        PokemonBattle.Batalla.accion(s.batalla, s.user, n)
        {:ok, s}
    end
  end

  defp ejecutar("clasificacion", _, s) do
    todos = GestorEntrenadores.todos()
    # Ordenar por victorias y luego por monedas acumuladas
    ordenados = Enum.sort_by(todos, &{-&1.victorias, -&1.monedas_acumuladas})

    IO.puts("\n=== CLASIFICACIÓN GLOBAL ===")
    Enum.with_index(ordenados, 1) |> Enum.each(fn {t, i} ->
      IO.puts("#{i}. #{t.usuario} - Wins: #{t.victorias} | total: #{t.monedas_acumuladas}")
    end)
    {:ok, s}
  end

  defp ejecutar("listar_equipos", _, s) do
    # información completa del entrenador
    t = GestorEntrenadores.obtener(s.user)

    if Map.equal?(t.equipos, %{}) do
      IO.puts("\nNo tienes equipos guardados. Usa 'crear_equipo' primero.")
    else
      IO.puts("\n=== TUS EQUIPOS GUARDADOS ===")

      Enum.each(t.equipos, fn {nombre, ids} ->
        # nombres de los pokemon en el inventario para mostrarlos
        pokes_nombres = Enum.map(ids, fn id ->
          pkm = Enum.find(t.inventario, &(&1.id == id))
          if pkm, do: "[##{id}] #{pkm.especie}", else: "[##{id}] DESCONOCIDO"
        end) |> Enum.join(", ")

        IO.puts("#{nombre} [#{length(ids)}/3]: #{pokes_nombres}")
      end)
    end
    {:ok, s}
  end

  defp ejecutar("cambiar", [id_str], s) do
    if s.batalla do
      id_buscado = String.to_integer(id_str)
      t = GestorEntrenadores.obtener(s.user)

      idx = Enum.find_index(t.inventario, &(&1.id == id_buscado))

      if idx do
        PokemonBattle.Batalla.cambiar_pokemon(s.batalla, s.user, idx)
        {:ok, %{s | esperando_cambio: false}}
      else
        {:error, "Ese Pokémon no está en tu inventario", s}
      end
    else
      {:error, "No estás en una batalla activa", s}
    end
  end

  # Fallback
  defp ejecutar(cmd, _, s), do: {:error, "Comando '#{cmd}' no existe", s}

  defp mostrar_ayuda(s) do
    IO.puts("""
    === COMANDOS DISPONIBLES ===

    CUENTA Y ECONOMÍA:
    - login <user> <pass>  : Iniciar sesión o registrarse
    - perfil               : Ver monedas y estadísticas
    - inventario           : Ver tus Pokémon y sus IDs
    - clasificacion        : Ranking global de entrenadores

    GESTIÓN DE EQUIPOS
    - crear_equipo <nom> <id1,id2,id3>
    - listar_equipos       : Ver tus equipos guardados
    - usar_equipo <nom>    : Seleccionar equipo para la batalla

    TIENDA Y SOBRES
    - comprar <tipo>       : Comprar sobre (basico/avanzado)
    - abrir                : Abrir el último sobre obtenido

    BATALLAS
    - conectar_nodo <node> : Conectarse a otra terminal
    - listar_salas         : Ver batallas disponibles
    - crear_sala <equipo>  : Crear sala de duelo
    - unirse <id> <equipo> : Entrar a una batalla
    - atacar <num>         : Usar movimiento (1-4)
    - cambiar <id_pkm>     : Cambiar Pokémon activo
    - rendirse             : Abandonar la batalla actual

    INTERCAMBIO
    - crear_trade          : Crear sala de intercambio
    - unirse_trade <cod>   : Unirse a sala de intercambio
    - ofrecer <id_pkm>     : Proponer Pokémon para cambio
    - confirmar_trade      : Aceptar el intercambio actual
    - cancelar_trade       : Cerrar sala de intercambio

    SISTEMA:
    - ayuda / salir
    """)
    {:ok, s}
  end
end
