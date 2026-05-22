defmodule PokemonBattle.GestorSalas do
  use GenServer

  alias PokemonBattle.{Batalla, Cluster, GestorEntrenadores}

  # Arrancamos el proceso con un mapa vacio
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  #  API
  def crear_sala(user, equipo), do: GenServer.call(__MODULE__, {:crear, user, equipo, self()})
  def unirse_sala(id, user, equipo), do: GenServer.call(__MODULE__, {:unirse, id, user, equipo, self()})
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
        id = "sala_#{map_size(state) + 1}"
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
          {:error, msg} -> {:reply, {:error, msg}, state}
          {:ok, pokes2} ->
            # Mandar la batalla al nodo con menos gente
            nodo = Cluster.nodo_menos_cargado()
            nueva_batalla(sala, {user2, pid2, pokes2}, nodo)

            {:reply, {:ok, id}, Map.delete(state, id)}
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

  defp chequear_equipo(nil, _), do: {:error, "No existes"}
  defp chequear_equipo(t, nom) do
    ids = t.equipos[nom]
    if is_nil(ids) or ids == [] do
      {:error, "Equipo no valido"}
    else
      # Buscar los pokes en el inventario
      pokes = Enum.map(ids, fn id -> Enum.find(t.inventario, &(&1.id == id)) end)
              |> Enum.filter(& &1) # Quitar nils

      if pokes == [], do: {:error, "No tienes esos pokes"}, else: {:ok, pokes}
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
      DynamicSupervisor.start_child(PokemonBattle.SupervisorBatallas, {Batalla, args})
    else
      :rpc.call(nodo, DynamicSupervisor, :start_child, [PokemonBattle.SupervisorBatallas, {Batalla, args}])
    end
  end
end
