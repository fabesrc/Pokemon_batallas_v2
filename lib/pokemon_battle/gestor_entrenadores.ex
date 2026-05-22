defmodule PokemonBattle.GestorEntrenadores do
  use GenServer
  alias PokemonBattle.Persistencia

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # API
  def iniciar_sesion(user, pass), do: GenServer.call(__MODULE__, {:login, user, pass, self()})
  def cerrar_sesion(user), do: GenServer.call(__MODULE__, {:logout, user, self()})
  def esta_en_sesion?(user), do: GenServer.call(__MODULE__, {:esta_on, user})
  def pid_sesion(user), do: GenServer.call(__MODULE__, {:get_pid, user})
  def obtener(user), do: GenServer.call(__MODULE__, {:get, user})
  def todos, do: GenServer.call(__MODULE__, :todos)

  # Acciones de dinero y items
  def actualizar_monedas(u, d), do: GenServer.call(__MODULE__, {:mod_money, u, d})
  def agregar_sobre(u, s), do: GenServer.call(__MODULE__, {:add_pack, u, s})
  def quitar_sobre(u, id), do: GenServer.call(__MODULE__, {:rem_pack, u, id})
  def agregar_pokemon(u, p), do: GenServer.call(__MODULE__, {:add_pkmn, u, p})
  def quitar_pokemon(u, id), do: GenServer.call(__MODULE__, {:rem_pkmn, u, id})
  def sumar_victoria(u), do: GenServer.call(__MODULE__, {:win, u})

  # Equipos
  def crear_equipo(u, nom, ids), do: GenServer.call(__MODULE__, {:new_team, u, nom, ids})
  def borrar_equipo(u, nom), do: GenServer.call(__MODULE__, {:del_team, u, nom})

  # Callbacks
  @impl true
  def init(:ok) do
    # Cargamos lo que haya en el archivo
    datos = Persistencia.cargar_entrenadores()
    trainers = Enum.reduce(datos, %{}, fn t, acc ->
      Map.put(acc, t["usuario"], limpiar_datos(t))
    end)
    {:ok, %{trainers: trainers, sessions: %{}}}
  end

  @impl true
  def handle_call({:login, user, pass, pid}, _from, state) do
    case state.trainers[user] do
      nil ->
        # Si no existe, lo creamos de una
        t = %{usuario: user, clave: pass, victorias: 0, monedas_actuales: 0, monedas_acumuladas: 0, inventario: [], sobres_pendientes: [], equipos: %{}}
        new_state = %{state | trainers: Map.put(state.trainers, user, t), sessions: Map.put(state.sessions, pid, user)}
        Process.monitor(pid)
        guardar(new_state)
        {:reply, {:ok, :registrado, t}, new_state}

      t ->
        if t.clave == pass do
          Process.monitor(pid)
          {:reply, {:ok, :entraste, t}, %{state | sessions: Map.put(state.sessions, pid, user)}}
        else
          {:reply, {:error, "Clave mal"}, state}
        end
    end
  end

  @impl true
  def handle_call({:mod_money, user, delta}, _from, state) do
    t = state.trainers[user]
    if t do
      nuevas = max(0, t.monedas_actuales + delta)
      acum = if delta > 0, do: t.monedas_acumuladas + delta, else: t.monedas_acumuladas
      t = %{t | monedas_actuales: nuevas, monedas_acumuladas: acum}
      new_state = put_in(state.trainers[user], t)
      guardar(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, "No existe"}, state}
    end
  end


  @impl true
  def handle_call({:add_pkmn, user, p}, _from, state) do
    t = state.trainers[user]
    t = %{t | inventario: t.inventario ++ [p]}
    new_state = put_in(state.trainers[user], t)
    guardar(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:win, user}, _from, state) do
    t = state.trainers[user]
    t = %{t | victorias: t.victorias + 1}
    new_state = put_in(state.trainers[user], t)
    guardar(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:new_team, user, nom, ids}, _from, state) do
    t = state.trainers[user]
    # Validación
    cond do
      Map.has_key?(t.equipos, nom) -> {:reply, {:error, "Ya existe"}, state}
      length(ids) > 3 -> {:reply, {:error, "Max 3"}, state}
      true ->
        t = %{t | equipos: Map.put(t.equipos, nom, ids)}
        new_state = put_in(state.trainers[user], t)
        guardar(new_state)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, %{state | sessions: Map.delete(state.sessions, pid)}}
  end

  # Mantenimiento de datos

  defp limpiar_datos(t) do
    # Esto convierte los strings del JSON a atomos
    %{
      usuario: t["usuario"],
      clave: t["clave"],
      victorias: t["victorias"] || 0,
      monedas_actuales: t["monedas_actuales"] || 0,
      monedas_acumuladas: t["monedas_acumuladas"] || 0,
      inventario: Enum.map(t["inventario"] || [], &limpiar_pkm/1),
      sobres_pendientes: Enum.map(t["sobres_pendientes"] || [], fn s -> %{id: s["id"], tipo: s["tipo"]} end),
      equipos: t["equipos"] || %{}
    }
  end

  defp limpiar_pkm(p) do
    %{
      id: p["id"], especie: p["especie"],
      rareza: p["rareza"], ataque: p["ataque"],
      defensa: p["defensa"], velocidad: p["velocidad"],
      movimientos: Enum.map(p["movimientos"] || [], fn m ->
        %{nombre: m["nombre"], tipo: m["tipo"], poder_base: m["poder_base"]}
      end)
    }
  end

  defp guardar(state) do
    # Convertir todo a lista y pasar a persistencia
    lista = Map.values(state.trainers) |> Enum.map(&preparar_para_json/1)
    Persistencia.guardar_entrenadores(lista)
  end

  defp preparar_para_json(t), do: t # En una version real aqui pasas atomos a strings
end
