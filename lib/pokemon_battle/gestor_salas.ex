defmodule PokemonBattle.GestorSalas do
  use GenServer

  alias PokemonBattle.{Batalla, Cluster, GestorEntrenadores}

  # Arrancamos el proceso con un mapa vacio
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  #  API
  def crear_sala(user, equipo), do: GenServer.call(__MODULE__, {:crear, user, equipo, self()})
  def unirse_sala(id, user, equipo) do
    nodos = [node() | Node.list()]

    Enum.find_value(nodos, {:error, "No existe esa sala en ningún nodo"}, fn n ->
      case :rpc.call(n, GenServer, :call, [__MODULE__, {:unirse, id, user, equipo, self()}]) do
        {:ok, res} -> {:ok, res}
        {:error, "No existe esa sala"} -> false
        {:error, msg} -> {:error, msg}
        # detectar problemas de red o cookies explícitamente
        {:badrpc, razon} -> {:error, "Error de conexión con nodo #{n}: #{inspect(razon)}"}
      end
    end)
  end

  def listar_salas, do: GenServer.call(__MODULE__, :listar)
  def cancelar_sala(id, user), do: GenServer.call(__MODULE__, {:cancelar, id, user})

  #  Callbacks
  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:crear, usuario, nom_equipo, pid}, _from, state) do
    t = GestorEntrenadores.obtener(usuario)

    case chequear_equipo(t, nom_equipo) do
      {:error, msg} -> {:reply, {:error, msg}, state}
      {:ok, pokes} ->
        # Generar un ID simple
        id = "S-#{map_size(state) + 1}"
        info = %{
          id: id,
          creador: usuario,
          pid: pid,
          equipo: pokes,
          nom_equipo: nom_equipo
        }
        send(pid, {:batalla_evento, "Sala #{id} lista. Esperando oponente..."})
        {:reply, {:ok, id}, Map.put(state, id, info)}
    end
  end

  @impl true
  def handle_call({:unirse, id, user2, equipo2, pid2}, _from, state) do
    sala = state[id]

    cond do
      is_nil(sala) ->
        {:reply, {:error, "No existe esa sala"}, state}

      sala.creador == user2 ->
        {:reply, {:error, "No juegues contigo mismo"}, state}

      true ->
        t2 = GestorEntrenadores.obtener(user2)

        case chequear_equipo(t2, equipo2) do
          {:error, msg} ->
            {:reply, {:error, msg}, state}

          {:ok, pokes2} ->
            nodo = Cluster.nodo_menos_cargado()

            # validamos el resultado de iniciar la batalla
            case nueva_batalla(sala, {user2, pid2, pokes2}, nodo) do
              {:ok, _pid} ->
                # Solo si la batalla inició con éxito, borramos la sala
                {:reply, {:ok, id}, Map.delete(state, id)}

              {:error, razon} ->
                {:reply, {:error, "Error al iniciar proceso de batalla: #{inspect(razon)}"}, state}

              {:badrpc, razon} ->
                {:reply, {:error, "Error de comunicación con el nodo #{nodo}: #{inspect(razon)}"}, state}
            end
        end
    end
  end

  @impl true
  def handle_call(:listar, _from, state) do
    res = for {id, s} <- state, do: %{id: id, user: s.creador, equipo: s.nom_equipo}
    {:reply, res, state}
  end

  @impl true
  def handle_call({:cancelar, id, user}, _from, state) do
    sala = state[id]
    if sala && sala.creador == user do
      {:reply, :ok, Map.delete(state, id)}
    else
      {:reply, {:error, "No puedes"}, state}
    end
  end

  # Privadas

  defp chequear_equipo(nil, _), do: {:error, "Entrenador no encontrado."}
  defp chequear_equipo(t, nom) do
    ids_guardados = t.equipos[nom]

    cond do
      is_nil(ids_guardados) or ids_guardados == [] ->
        {:error, "El equipo '#{nom}' no existe o no tiene Pokémon asignados."}

      true ->
        # objeto completo de cada Pokémon por su ID
        busqueda = Enum.map(ids_guardados, fn id ->
          {id, Enum.find(t.inventario, &(&1.id == id))}
        end)

        # IDs que resultaron en nil
        faltantes =
          busqueda
          |> Enum.filter(fn {_id, pkm} -> is_nil(pkm) end)
          |> Enum.map(fn {id, _pkm} -> id end)

        if faltantes == [] do
          pokes_objetos = Enum.map(busqueda, fn {_id, pkm} -> pkm end)
          {:ok, pokes_objetos}
        else
          # rechazar e indicar cuáles pokemones faltan
          ids_str = Enum.join(faltantes, ", ")
          {:error, "Equipo inválido. Los Pokémon con ID [#{ids_str}] ya no están en tu inventario."}
        end
    end
  end

  defp nueva_batalla(sala, {u2, p2, e2}, nodo) do
    args = [
      sala_id: sala.id,
      j1: {sala.creador, sala.pid, sala.equipo},
      j2: {u2, p2, e2},
      nodo: nodo
    ]

    # Si es mi nodo, directo, de lo contrario rpc.
    if nodo == node() do
      DynamicSupervisor.start_child(PokemonBattle.SupBatallas, {Batalla, args})
    else
      :rpc.call(nodo, DynamicSupervisor, :start_child, [PokemonBattle.SupBatallas, {Batalla, args}])
    end
  end
end
