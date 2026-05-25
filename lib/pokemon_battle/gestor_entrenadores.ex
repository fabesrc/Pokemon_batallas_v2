defmodule PokemonBattle.GestorEntrenadores do
  use GenServer
  alias PokemonBattle.Persistencia

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # API
  def iniciar_sesion(user, pass), do: iniciar_sesion_con_pid(user, pass, self())

  def iniciar_sesion_con_pid(user, pass, pid_externo) do
    GenServer.call(__MODULE__, {:login, user, pass, pid_externo})
  end
  def cerrar_sesion(user), do: GenServer.call(__MODULE__, {:logout, user, self()})
  def esta_en_sesion?(user), do: GenServer.call(__MODULE__, {:esta_on, user})
  def pid_sesion(user), do: GenServer.call(__MODULE__, {:get_pid, user})

  def obtener(user) do
    call_en_nodo(user, {:get, user})
  end

  def todos, do: GenServer.call(__MODULE__, :todos)

  # Acciones de dinero y items (siempre en el nodo donde el usuario tiene sesión)
  def actualizar_monedas(u, d), do: call_en_nodo(u, {:mod_money, u, d})
  def agregar_sobre(u, s), do: call_en_nodo(u, {:add_pack, u, s})
  def quitar_sobre(u, id), do: call_en_nodo(u, {:rem_pack, u, id})
  def agregar_pokemon(u, p), do: call_en_nodo(u, {:add_pkmn, u, p})
  def quitar_pokemon(u, id), do: call_en_nodo(u, {:rem_pkmn, u, id})
  def sumar_victoria(u), do: call_en_nodo(u, {:win, u})

  # Equipos
  def crear_equipo(u, nom, ids), do: call_en_nodo(u, {:new_team, u, nom, ids})
  def borrar_equipo(u, nom), do: call_en_nodo(u, {:del_team, u, nom})

  # Envía la operación al nodo donde el jugador inició sesión (evita datos desactualizados en clúster)
  defp call_en_nodo(user, msg) do
    nodo =
      Enum.find_value([node() | Node.list()], fn n ->
        case :rpc.call(n, __MODULE__, :esta_en_sesion?, [user]) do
          true -> n
          _ -> nil
        end
      end) || node()

    if nodo == node() do
      GenServer.call(__MODULE__, msg)
    else
      case :rpc.call(nodo, GenServer, :call, [__MODULE__, msg]) do
        {:badrpc, razon} -> {:error, "Error de red con #{nodo}: #{inspect(razon)}"}
        res -> res
      end
    end
  end

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
        t = %{
          usuario: user,
          clave: pass,
          victorias: 0,
          monedas_actuales: 0,
          monedas_acumuladas: 0,
          inventario: [],
          # Se agrega el sobre básico inicial de bienvenida
          sobres_pendientes: [%{id: :rand.uniform(999_999), tipo: "basico"}],
          equipos: %{}
        }
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
  def handle_call({:logout, _user, pid}, _from, state) do
    {:reply, :ok, %{state | sessions: Map.delete(state.sessions, pid)}}
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
  def handle_call({:rem_pkmn, user, id}, _from, state) do
    t = state.trainers[user]
    nuevo_inv = Enum.reject(t.inventario, &(&1.id == id))
    t = %{t | inventario: nuevo_inv}
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
  def handle_call({:del_team, user, nombre_equipo}, _from, state) do
    t = state.trainers[user]
    t = %{t | equipos: Map.delete(t.equipos, nombre_equipo)}
    new_state = put_in(state.trainers[user], t)
    guardar(new_state)
    {:reply, :ok, new_state}
  end
  @impl true
  def handle_call({:get, user}, _from, state) do
    {:reply, state.trainers[user], state}
  end
  @impl true
  def handle_call({:add_pack, user, sobre}, _from, state) do
    t = state.trainers[user]
    t = %{t | sobres_pendientes: t.sobres_pendientes ++ [sobre]}
    new_state = put_in(state.trainers[user], t)
    guardar(new_state)
    {:reply, :ok, new_state}
  end
  @impl true
  def handle_call({:rem_pack, user, id}, _from, state) do
    t = state.trainers[user]
    # Filtramos la lista para quitar el sobre usado
    nuevos_sobres = Enum.reject(t.sobres_pendientes, &(&1.id == id))
    t = %{t | sobres_pendientes: nuevos_sobres}
    new_state = put_in(state.trainers[user], t)
    guardar(new_state)
    {:reply, :ok, new_state}
  end
  @impl true
  def handle_call(:todos, _from, state) do
    # Devuelve todos los entrenadores para la tabla de posiciones
    {:reply, Map.values(state.trainers), state}
  end
  @impl true
  def handle_call({:esta_on, user}, _from, state) do
    # Busca si el usuario tiene una sesión activa (PID)
    is_on = Enum.any?(state.sessions, fn {_pid, u} -> u == user end)
    {:reply, is_on, state}
  end
  @impl true
  def handle_call({:get_pid, user}, _from, state) do
    # Obtiene el PID de un usuario conectado
    pid = Enum.find_value(state.sessions, fn {p, u} -> if u == user, do: p end)
    {:reply, pid, state}
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
      id: p["id"],
      especie: p["especie"],
      rareza: p["rareza"],
      ataque: p["ataque"],
      defensa: p["defensa"],
      velocidad: p["velocidad"],
      dueño_original: p["dueño_original"],
      movimientos: Enum.map(p["movimientos"] || [], fn m ->
        %{nombre: m["nombre"], tipo: m["tipo"], poder_base: m["poder_base"]}
      end)
    }
  end

  defp guardar(state) do
    # convertir todo a lista y pasar a persistencia
    lista = Map.values(state.trainers) |> Enum.map(&preparar_para_json/1)
    Persistencia.guardar_entrenadores(lista)
  end

  defp preparar_para_json(t) do
    %{
      "usuario" => t.usuario,
      "clave" => t.clave,
      "victorias" => t.victorias,
      "monedas_actuales" => t.monedas_actuales,
      "monedas_acumuladas" => t.monedas_acumuladas,
      "sobres_pendientes" => Enum.map(t.sobres_pendientes, fn s ->
        %{"id" => s.id, "tipo" => s.tipo}
      end),
      "inventario" => Enum.map(t.inventario, &preparar_pkm_json/1),
      "equipos" => t.equipos
    }
  end

  # auxiliar para procesar cada Pokémon del inventario
  defp preparar_pkm_json(p) do
    %{
      "id" => p.id,
      "especie" => p.especie,
      "rareza" => Map.get(p, :rareza, "comun"),
      "ataque" => p.ataque,
      "defensa" => p.defensa,
      "velocidad" => p.velocidad,
      "dueño_original" => p.dueño_original,
      "movimientos" => Enum.map(p.movimientos || [], fn m ->
        %{
          "nombre" => Map.get(m, :nombre),
          "tipo" => Map.get(m, :tipo),
          "poder_base" => Map.get(m, :poder_base)
        }
      end)
    }
  end
end
