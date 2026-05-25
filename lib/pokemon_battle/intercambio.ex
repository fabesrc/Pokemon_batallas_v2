defmodule PokemonBattle.Intercambio do
  @moduledoc """
  Proceso de intercambio 1-a-1 entre dos entrenadores (patrón GenServer por sesión).
  """
  use GenServer, restart: :temporary

  alias PokemonBattle.GestorEntrenadores

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {PokemonBattle.Registry, {:intercambio, id}}}

  # API con enrutamiento en clúster
  def ofrecer(id, nom, pok_id) do
    with {:ok, nodo} <- nodo_intercambio(id),
         res <- llamar_en_nodo(nodo, id, {:ofrecer, nom, parse_id(pok_id)}) do
      res
    else
      {:error, msg} -> {:error, msg}
    end
  end

  def confirmar(id, nom) do
    with {:ok, nodo} <- nodo_intercambio(id),
         res <- llamar_en_nodo(nodo, id, {:confirmar, nom}) do
      res
    else
      {:error, msg} -> {:error, msg}
    end
  end

  def cancelar(id, nom) do
    with {:ok, nodo} <- nodo_intercambio(id),
         res <- llamar_en_nodo(nodo, id, {:cancelar, nom}) do
      res
    else
      {:error, msg} -> {:error, msg}
    end
  end

  def ofrecer_en_nodo(id, nom, pok_id),
    do: GenServer.call(via(id), {:ofrecer, nom, parse_id(pok_id)}, 5_000)

  def confirmar_en_nodo(id, nom),
    do: GenServer.call(via(id), {:confirmar, nom}, 5_000)

  def cancelar_en_nodo(id, nom),
    do: GenServer.call(via(id), {:cancelar, nom}, 5_000)

  defp llamar_en_nodo(nodo, id, msg) do
    if nodo == node() do
      GenServer.call(via(id), msg, 5_000)
    else
      case msg do
        {:ofrecer, nom, pid} -> :rpc.call(nodo, __MODULE__, :ofrecer_en_nodo, [id, nom, pid])
        {:confirmar, nom} -> :rpc.call(nodo, __MODULE__, :confirmar_en_nodo, [id, nom])
        {:cancelar, nom} -> :rpc.call(nodo, __MODULE__, :cancelar_en_nodo, [id, nom])
      end
    end
  end

  defp nodo_intercambio(id) do
    case Enum.find_value([node() | Node.list()], fn n ->
           case :rpc.call(n, Registry, :lookup, [PokemonBattle.Registry, {:intercambio, id}]) do
             [{_pid, _}] -> n
             _ -> nil
           end
         end) do
      nil -> {:error, "Intercambio #{id} no encontrado o ya terminó"}
      n -> {:ok, n}
    end
  end

  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(id) when is_binary(id), do: String.to_integer(id)

  @impl true
  def init(opts) do
    state = %{
      id: opts[:id],
      j1: %{nombre: opts[:nombre1], pid: opts[:pid1], ofrece: nil, ok: false},
      j2: %{nombre: opts[:nombre2], pid: opts[:pid2], ofrece: nil, ok: false},
      status: :esperando
    }

    aviso_ambos(state, "Intercambio #{state.id} listo. Usa: ofrecer <id_pokemon> y luego confirmar_trade")

    {:ok, state}
  end

  @impl true
  def handle_call({:ofrecer, nombre, pokemon_id}, _from, state) do
    cond do
      state.status in [:cancelado, :fin] ->
        {:reply, {:error, "Intercambio cancelado o finalizado"}, state}

      true ->
        case GestorEntrenadores.obtener(nombre) do
          nil ->
            {:reply, {:error, "Entrenador no encontrado"}, state}

          {:error, msg} ->
            {:reply, {:error, msg}, state}

          trainer ->
            tiene = Enum.find(trainer.inventario, &(&1.id == pokemon_id))

            equipos_con_pkm =
              trainer.equipos
              |> Enum.filter(fn {_nom, ids} -> pokemon_id in ids end)
              |> Enum.map(fn {nom, _} -> nom end)

            cond do
              is_nil(tiene) ->
                {:reply, {:error, "No tienes ese Pokémon (ID #{pokemon_id}) en tu inventario"}, state}

              equipos_con_pkm != [] ->
                nombres = Enum.join(equipos_con_pkm, ", ")

                {:reply,
                 {:error,
                  """
                  El Pokémon ##{pokemon_id} está en el/los equipo(s): #{nombres}
                  Antes de intercambiarlo usa: borrar_equipo <nombre>
                  Luego vuelve a crear el equipo sin ese ID si lo necesitas.
                  """},
                 state}

              true ->
                nuevo_j = %{get_j(state, nombre) | ofrece: pokemon_id, ok: false}
                new_state = set_j(state, nuevo_j)

                aviso(new_state, nombre, "Ofreciste #{tiene.especie} (ID: #{pokemon_id})")
                aviso_al_otro(new_state, nombre, "#{nombre} ofrece un Pokémon...")

                new_state =
                  if new_state.j1.ofrece && new_state.j2.ofrece do
                    mostrar_confirmacion(new_state)
                    %{new_state | status: :confirmando}
                  else
                    new_state
                  end

                {:reply, :ok, new_state}
            end
        end
    end
  end

  @impl true
  def handle_call({:confirmar, nombre}, _from, state) do
    cond do
      state.status != :confirmando ->
        {:reply, {:error, "Ambos deben usar 'ofrecer <id>' antes de confirmar"}, state}

      is_nil(get_j(state, nombre).ofrece) ->
        {:reply, {:error, "Primero ofrece un Pokémon con: ofrecer <id>"}, state}

      true ->
        j = %{get_j(state, nombre) | ok: true}
        state = set_j(state, j)

        aviso(state, nombre, "Confirmaste. Esperando al otro jugador...")

        if state.j1.ok && state.j2.ok do
          {:reply, :ok, hacer_cambio(state)}
        else
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:cancelar, nombre}, _from, state) do
    aviso_ambos(state, "Intercambio cancelado por #{nombre}")
    {:reply, :ok, %{state | status: :cancelado}}
  end

  defp hacer_cambio(s) do
    t1 = GestorEntrenadores.obtener(s.j1.nombre)
    t2 = GestorEntrenadores.obtener(s.j2.nombre)

    p1 = Enum.find(t1.inventario, &(&1.id == s.j1.ofrece))
    p2 = Enum.find(t2.inventario, &(&1.id == s.j2.ofrece))

    GestorEntrenadores.quitar_pokemon(s.j1.nombre, s.j1.ofrece)
    GestorEntrenadores.quitar_pokemon(s.j2.nombre, s.j2.ofrece)

    GestorEntrenadores.agregar_pokemon(s.j1.nombre, p2)
    GestorEntrenadores.agregar_pokemon(s.j2.nombre, p1)

    send(s.j1.pid, {:intercambio_evento, "¡Recibiste #{p2.especie}! (ID: #{p2.id})"})
    send(s.j2.pid, {:intercambio_evento, "¡Recibiste #{p1.especie}! (ID: #{p1.id})"})

    aviso_ambos(s, "¡Intercambio completado con éxito!")

    send(s.j1.pid, {:intercambio_completado, s.id})
    send(s.j2.pid, {:intercambio_completado, s.id})

    %{s | status: :fin}
  end

  defp get_j(s, nom), do: if(s.j1.nombre == nom, do: s.j1, else: s.j2)
  defp set_j(s, j), do: if(s.j1.nombre == j.nombre, do: %{s | j1: j}, else: %{s | j2: j})

  defp aviso(s, nombre, msg), do: send(get_j(s, nombre).pid, {:intercambio_evento, msg})

  defp aviso_al_otro(s, nom, msg) do
    dest = if s.j1.nombre == nom, do: s.j2.pid, else: s.j1.pid
    send(dest, {:intercambio_evento, msg})
  end

  defp aviso_ambos(s, msg) do
    send(s.j1.pid, {:intercambio_evento, msg})
    send(s.j2.pid, {:intercambio_evento, msg})
  end

  defp mostrar_confirmacion(s) do
    t1 = GestorEntrenadores.obtener(s.j1.nombre)
    t2 = GestorEntrenadores.obtener(s.j2.nombre)

    p1 = Enum.find(t1.inventario, &(&1.id == s.j1.ofrece))
    p2 = Enum.find(t2.inventario, &(&1.id == s.j2.ofrece))

    aviso_ambos(
      s,
      """
      Ambos ofrecieron:
        #{s.j1.nombre} -> #{p1.especie} (ID: #{p1.id})
        #{s.j2.nombre} -> #{p2.especie} (ID: #{p2.id})
      Escribe 'confirmar_trade' en ambas terminales para completar el cambio.
      """
    )
  end
end
