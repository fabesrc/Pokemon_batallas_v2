defmodule PokemonBattle.Servidor do
  alias PokemonBattle.{
    GestorEntrenadores, GestorSalas, SistemaSobres,
    Intercambio, Cluster, Persistencia
  }

  # Estado de la sesion actual del jugador
  defstruct [
    user: nil,      # Nombre del usuario
    sala: nil,      # Sala si esta esperando
    batalla: nil,   # ID de la batalla si esta peleando
    trade: nil      # ID del intercambio
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
      {:batalla_evento, msg} ->
        IO.puts("\n[BATALLA] #{msg}")
        revisar_buzon(state)
      {:batalla_terminada, %{ganador: g}} ->
        IO.puts("\n*** BATALLA TERMINADA. GANÓ: #{g} ***")
        %{state | batalla: nil, sala: nil}
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
    [cmd | args] = String.split(input, " ")
    ejecutar(cmd, args, state)
  end

  # Lógica de Comandos
1
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
      {:ok, id} -> IO.puts("Sala #{id} creada."); {:ok, %{s | sala: id}}
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
    if s.batalla do
      PokemonBattle.Batalla.accion(s.batalla, s.user, n)
      {:ok, s}
    else
      {:error, "No estas peleando", s}
    end
  end

  # Fallback
  defp ejecutar(cmd, _, s), do: {:error, "Comando '#{cmd}' no existe", s}

  defp mostrar_ayuda(s) do
    IO.puts("""
    COMANDOS DISPONIBLES:
    - login <user> <pass>
    - perfil / inventario
    - crear_equipo <nombre> <id1,id2,id3>
    - comprar <tipo> / abrir
    - crear_sala <equipo> / unirse <id> <equipo>
    - atacar <numero> / pasar
    - conectar_nodo <nombre>
    - salir
    """)
    {:ok, s}
  end
end
