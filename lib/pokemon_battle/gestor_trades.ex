defmodule PokemonBattle.GestorTrades do
  @moduledoc """
  Gestiona salas de intercambio pendientes (patrón similar a GestorSalas).
  """
  use GenServer

  alias PokemonBattle.{Intercambio, GestorEntrenadores}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def crear(user) do
    pid = GestorEntrenadores.pid_sesion(user) || self()
    GenServer.call(__MODULE__, {:crear, user, pid})
  end

  def unirse(id, user) do
    pid = GestorEntrenadores.pid_sesion(user) || self()
    nodos = [node() | Node.list()]

    Enum.find_value(nodos, {:error, "No existe esa sala de intercambio"}, fn n ->
      case :rpc.call(n, GenServer, :call, [__MODULE__, {:unirse, id, user, pid}]) do
        {:ok, res} -> {:ok, res}
        {:error, "No existe esa sala de intercambio"} -> false
        {:error, msg} -> {:error, msg}
        {:badrpc, razon} -> {:error, "Error de conexión con nodo #{n}: #{inspect(razon)}"}
      end
    end)
  end

  def listar, do: GenServer.call(__MODULE__, :listar)

  def cancelar_pendiente(id, user), do: GenServer.call(__MODULE__, {:cancelar, id, user})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:crear, usuario, pid}, _from, state) do
    id = "T-#{map_size(state) + 1}"

    info = %{id: id, creador: usuario, pid: pid}

    send(pid, {:intercambio_evento, "Sala de intercambio #{id} creada. Esperando socio..."})

    {:reply, {:ok, id}, Map.put(state, id, info)}
  end

  @impl true
  def handle_call({:unirse, id, user2, pid2}, _from, state) do
    trade = state[id]

    cond do
      is_nil(trade) ->
        {:reply, {:error, "No existe esa sala de intercambio"}, state}

      trade.creador == user2 ->
        {:reply, {:error, "No puedes unirte a tu propio intercambio"}, state}

      true ->
        args = [
          id: id,
          nombre1: trade.creador,
          pid1: trade.pid,
          nombre2: user2,
          pid2: pid2
        ]

        case DynamicSupervisor.start_child(PokemonBattle.SupIntercambios, {Intercambio, args}) do
          {:ok, _pid} ->
            send(pid2, {:intercambio_evento, "Te uniste al intercambio #{id}"})
            {:reply, {:ok, id}, Map.delete(state, id)}

          {:error, {:already_started, _}} ->
            {:reply, {:error, "Ese intercambio ya está en curso"}, state}

          {:error, razon} ->
            {:reply, {:error, "No se pudo iniciar el intercambio: #{inspect(razon)}"}, state}
        end
    end
  end

  @impl true
  def handle_call(:listar, _from, state) do
    res = for {id, t} <- state, do: %{id: id, creador: t.creador}
    {:reply, res, state}
  end

  @impl true
  def handle_call({:cancelar, id, user}, _from, state) do
    trade = state[id]

    if trade && trade.creador == user do
      send(trade.pid, {:intercambio_evento, "Sala #{id} cancelada."})
      {:reply, :ok, Map.delete(state, id)}
    else
      {:reply, {:error, "No puedes cancelar esta sala"}, state}
    end
  end
end
