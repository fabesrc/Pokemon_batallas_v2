defmodule PokemonBattle.Batalla do
  use GenServer, restart: :temporary
  alias PokemonBattle.{MotorCombate, GestorEntrenadores, Persistencia}

  @t_turno 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:sala_id]))
  end

  def via(id), do: {:via, Registry, {PokemonBattle.Registry, {:batalla, id}}}

  # API (enruta al nodo donde vive el proceso de batalla)
  def accion(id, user, act) do
    case nodo_batalla(id) do
      nil ->
        {:error, "No se encontró la batalla #{id}. ¿Sigue activa?"}

      n when n == node() ->
        GenServer.call(via(id), {:accion, user, act}, 5_000)

      n ->
        case :rpc.call(n, __MODULE__, :accion_en_nodo, [id, user, act]) do
          {:badrpc, razon} -> {:error, "Error de red con #{n}: #{inspect(razon)}"}
          res -> res
        end
    end
  end

  def accion_en_nodo(id, user, act), do: GenServer.call(via(id), {:accion, user, act}, 5_000)

  def cambiar_pokemon(id, user, idx) do
    case nodo_batalla(id) do
      nil ->
        {:error, "No se encontró la batalla #{id}"}

      n when n == node() ->
        GenServer.call(via(id), {:cambio, user, idx}, 5_000)

      n ->
        case :rpc.call(n, __MODULE__, :cambiar_en_nodo, [id, user, idx]) do
          {:badrpc, razon} -> {:error, "Error de red con #{n}: #{inspect(razon)}"}
          res -> res
        end
    end
  end

  def cambiar_en_nodo(id, user, idx), do: GenServer.call(via(id), {:cambio, user, idx}, 5_000)

  defp nodo_batalla(id) do
    Enum.find_value([node() | Node.list()], fn n ->
      case :rpc.call(n, Registry, :lookup, [PokemonBattle.Registry, {:batalla, id}]) do
        [{_pid, _}] -> n
        [] -> nil
        _ -> nil
      end
    end)
  end

  # Callbacks
  @impl true
  def init(opts) do
    catalogo = Persistencia.cargar_pokemon()

    # Cacheamos los tipos para no leer disco en cada golpe
    tipos = for p <- catalogo, into: %{}, do: {p["especie"], p["tipos"]}

    state = %{
      id: opts[:sala_id],
      j1: crear_j(opts[:j1], tipos),
      j2: crear_j(opts[:j2], tipos),
      turno: 1,
      acts: %{},
      timer_ref: nil,
      status: :jugando,
      reemplazos: [],
      nodo: opts[:nodo] || node()
    }

    # Primer aviso
    aviso_ambos(state, "--- Batalla Iniciada! ---")
    mostrar_opciones(state)

    {:ok, iniciar_timer(state)}
  end

  @impl true
  def handle_call({:accion, user, act}, _from, state) do
    cond do
      state.status == :reemplazo ->
        j = get_j(state, user)

        {:reply,
         {:error,
          "Debes elegir otro Pokémon. Usa: cambiar <id>\n#{texto_equipo_disponible(j)}"},
         state}

      state.status == :fin ->
        {:reply, {:error, "La batalla ya terminó"}, state}

      state.status != :jugando ->
        {:reply, {:error, "No puedes atacar en este momento"}, state}

      Map.has_key?(state.acts, user) ->
        {:reply, {:error, "Ya enviaste tu movimiento este turno. Espera al rival o al siguiente turno."},
         state}

      true ->
        new_acts = Map.put(state.acts, user, act)

        if map_size(new_acts) == 2 do
          state = cancelar_timer(state)
          new_state = procesar_turno(%{state | acts: new_acts})
          {:reply, :ok, new_state}
        else
          {p_actual, p_rival} = j_y_rival(state, user)

          send(p_actual.pid,
                {:batalla_evento,
                 "Orden recibida. Esperando a que #{p_rival.nombre} elija su movimiento..."})

          send(p_rival.pid,
                {:batalla_evento,
                 "¡#{user} ya envió su ataque! El turno se resolverá en cuanto tú elijas."})

          {:reply, :ok, %{state | acts: new_acts}}
        end
    end
  end

  @impl true
  def handle_call({:cambio, user, idx}, _from, state) do
    if user in state.reemplazos do
      j = get_j(state, user)

      cond do
        idx < 0 or idx >= length(j.pokes) ->
          {:reply, {:error, "Índice de Pokémon inválido"}, state}

        Enum.at(j.hp, idx) <= 0 ->
          {:reply,
           {:error,
            "Ese Pokémon está debilitado y no puede combatir.\n#{texto_equipo_disponible(j)}"},
           state}

        idx == j.activo ->
          {:reply,
           {:error,
            "Ese Pokémon ya está en combate (debilitado). Elige otro:\n#{texto_equipo_disponible(j)}"},
           state}

        true ->
          pkm = Enum.at(j.pokes, idx)
          hp = Enum.at(j.hp, idx)

          send(j.pid,
                {:batalla_evento,
                 "¡#{pkm.especie} entra al combate! (HP: #{hp}/100, ID: #{pkm.id})"})

          nuevo_j = %{j | activo: idx}
          state = set_j(state, nuevo_j)
          restantes = List.delete(state.reemplazos, user)

          new_state =
            if restantes == [] do
              nuevo_turno(%{state | reemplazos: []})
            else
              %{state | reemplazos: restantes}
            end

          {:reply, :ok, new_state}
      end
    else
      {:reply, {:error, "No necesitas cambiar de Pokémon ahora"}, state}
    end
  end

  # Ignorar mensajes viejos del formato anterior (:timeout sin ref)
  @impl true
  def handle_info(:timeout, state), do: {:noreply, state}

  @impl true
  def handle_info({:timeout, ref}, state) do
    # Ignorar timeouts viejos que quedaron en el buzón tras cancelar el timer
    if state.timer_ref == ref and state.status == :jugando do
      faltan =
        [state.j1.nombre, state.j2.nombre]
        |> Enum.reject(&Map.has_key?(state.acts, &1))

      if faltan != [] do
        aviso_ambos(state, "Tiempo agotado. #{Enum.join(faltan, " y ")} no eligió a tiempo.")
      end

      acts =
        state.acts
        |> Map.put_new(state.j1.nombre, "pasar")
        |> Map.put_new(state.j2.nombre, "pasar")

      state = cancelar_timer(state)
      {:noreply, procesar_turno(%{state | acts: acts})}
    else
      {:noreply, state}
    end
  end

  # Lógica de Turno

  defp procesar_turno(s) do
    # Quien va primero según velocidad
    v1 = Enum.at(s.j1.pokes, s.j1.activo).velocidad
    v2 = Enum.at(s.j2.pokes, s.j2.activo).velocidad

    orden = if MotorCombate.orden_turno(v1, v2) == :j1_primero,
              do: [s.j1, s.j2],
              else: [s.j2, s.j1]

    # Ejecutar ataques
    s = Enum.reduce(orden, s, fn atacante, acc ->
      # Solo ataca si no ha muerto en este mismo turno
      if tiene_hp?(get_j(acc, atacante.nombre)), do: ejecutar_ataque(acc, atacante.nombre), else: acc
    end)

    # limpiar acciones
    s = %{s | acts: %{}}
    chequear_final(s)
  end

  defp ejecutar_ataque(s, nom_atk) do
    if Map.get(s.acts, nom_atk) == "pasar", do: s

    {atk, defen} = j_y_rival(s, nom_atk)
    p_atk = Enum.at(atk.pokes, atk.activo)
    p_def = Enum.at(defen.pokes, defen.activo)

    mov_idx = case Integer.parse(s.acts[nom_atk] || "") do
      {num, _} -> num - 1
      :error -> 0
    end
    mov = Enum.at(p_atk.movimientos, mov_idx) || hd(p_atk.movimientos)

    dano = MotorCombate.calcular_dano(mov, p_atk, p_def, atk.tipos[p_atk.especie], defen.tipos[p_def.especie])
    nueva_hp = max(0, Enum.at(defen.hp, defen.activo) - dano)
    defen = %{defen | hp: List.replace_at(defen.hp, defen.activo, nueva_hp)}

    # [NUEVO] mensaje personalizado para que cada uno sepa qué pasó
    send(atk.pid, {:batalla_evento, "¡Tu #{p_atk.especie} usó #{mov.nombre} e hizo #{dano} de daño!"})
    send(defen.pid, {:batalla_evento, "¡El #{p_atk.especie} de #{nom_atk} usó #{mov.nombre} y te quitó #{dano} HP!"})

    if nueva_hp == 0 do
      aviso_ambos(s, "¡El #{p_def.especie} de #{defen.nombre} se ha debilitado!")
    end

    set_j(s, defen)
  end


  defp chequear_final(s) do
    v1 = Enum.any?(s.j1.hp, & &1 > 0)
    v2 = Enum.any?(s.j2.hp, & &1 > 0)

    cond do
      not v1 and not v2 -> terminar(s, :empate)
      not v1 -> terminar(s, s.j2.nombre)
      not v2 -> terminar(s, s.j1.nombre)
      true ->

        muertos = for j <- [s.j1, s.j2], Enum.at(j.hp, j.activo) <= 0, do: j.nombre

        if muertos == [] do
          nuevo_turno(s)
        else
          iniciar_fase_reemplazo(s, muertos)
        end
    end
  end

  defp nuevo_turno(s) do
    s =
      s
      |> cancelar_timer()
      |> Map.merge(%{turno: s.turno + 1, status: :jugando, acts: %{}})

    mostrar_opciones(s)
    iniciar_timer(s)
  end

  defp terminar(s, ganador) do
    s = cancelar_timer(s)
    if ganador != :empate do
      perdedor = if s.j1.nombre == ganador, do: s.j2.nombre, else: s.j1.nombre
      aviso_ambos(s, "FIN: Ganador #{ganador} (+100 monedas) | #{perdedor} (+30 monedas)")
    else
      aviso_ambos(s, "FIN: Empate")
    end

    send(s.j1.pid, {:batalla_terminada, %{ganador: ganador, sala_id: s.id}})
    send(s.j2.pid, {:batalla_terminada, %{ganador: ganador, sala_id: s.id}})

    if ganador != :empate do
      perdedor = if s.j1.nombre == ganador, do: s.j2.nombre, else: s.j1.nombre

      # recompensa ganador: +100
      GestorEntrenadores.sumar_victoria(ganador)
      GestorEntrenadores.actualizar_monedas(ganador, 100)

      # recompensa perdedor: +30
      GestorEntrenadores.actualizar_monedas(perdedor, 30)

      # Registrar en el log
      Persistencia.registrar_batalla(%{
        jugador1: s.j1.nombre,
        jugador2: s.j2.nombre,
        ganador: ganador,
        turnos: s.turno,
        nodo: s.nodo
      })
    end

    %{s | status: :fin}
  end

  # Helpers sucios

  defp crear_j({nom, pid, equipo}, tipos) do
    %{
      nombre: nom,
      pid: pid,
      pokes: equipo,
      activo: 0,
      hp: Enum.map(equipo, fn _ -> 100 end),
      tipos: tipos
    }
  end

  defp iniciar_timer(s) do
    ref = make_ref()
    Process.send_after(self(), {:timeout, ref}, @t_turno)
    %{s | timer_ref: ref}
  end

  defp cancelar_timer(s) do
    if s.timer_ref, do: Process.cancel_timer(s.timer_ref)
    %{s | timer_ref: nil}
  end

  defp get_j(s, nom), do: if(s.j1.nombre == nom, do: s.j1, else: s.j2)
  defp set_j(s, j), do: if(s.j1.nombre == j.nombre, do: %{s | j1: j}, else: %{s | j2: j})
  defp j_y_rival(s, nom), do: if(s.j1.nombre == nom, do: {s.j1, s.j2}, else: {s.j2, s.j1})
  defp tiene_hp?(j), do: Enum.at(j.hp, j.activo) > 0

  defp iniciar_fase_reemplazo(s, muertos) do
    s = cancelar_timer(s)

    {s, pendientes} =
      Enum.reduce_while(muertos, {s, []}, fn nombre, {acc, lista} ->
        j = get_j(acc, nombre)
        disponibles = indices_disponibles(j)

        if disponibles == [] do
          {:halt, {terminar(acc, rival_de(acc, nombre)), []}}
        else
          notificar_reemplazo(j, disponibles)
          {:cont, {acc, [nombre | lista]}}
        end
      end)

    if pendientes == [] do
      s
    else
      %{s | status: :reemplazo, reemplazos: pendientes}
    end
  end

  defp rival_de(s, nombre), do: if(s.j1.nombre == nombre, do: s.j2.nombre, else: s.j1.nombre)

  defp indices_disponibles(j) do
    j.hp
    |> Enum.with_index()
    |> Enum.filter(fn {hp, _idx} -> hp > 0 end)
    |> Enum.map(fn {_hp, idx} -> idx end)
  end

  defp notificar_reemplazo(j, disponibles) do
    debilitado = Enum.at(j.pokes, j.activo)

    send(j.pid,
         {:batalla_evento,
          """
          Esperando cambios de pokemon...

          ¡Tu #{debilitado.especie} (ID: #{debilitado.id}) se debilitó y no puede seguir en combate!

          Elige tu siguiente Pokémon con: cambiar <id>
          #{texto_lista_disponibles(j, disponibles)}

          #{texto_lista_debilitados(j, disponibles)}
          """})
  end

  defp texto_lista_disponibles(j, disponibles) do
    lineas =
      Enum.map(disponibles, fn idx ->
        p = Enum.at(j.pokes, idx)
        hp = Enum.at(j.hp, idx)
        "  -> cambiar #{p.id}   #{p.especie} (HP: #{hp}/100)"
      end)

    "Pokémon DISPONIBLES:\n" <> Enum.join(lineas, "\n")
  end

  defp texto_lista_debilitados(j, disponibles) do
    debilitados =
      j.pokes
      |> Enum.with_index()
      |> Enum.reject(fn {_p, idx} -> idx in disponibles end)

    if debilitados == [] do
      ""
    else
      lineas =
        Enum.map(debilitados, fn {p, _idx} ->
          "  x  ##{p.id}   #{p.especie}  (DEBILITADO - no se puede usar)"
        end)

      "Pokémon NO disponibles:\n" <> Enum.join(lineas, "\n")
    end
  end

  defp texto_equipo_disponible(j) do
    disponibles = indices_disponibles(j)
    texto_lista_disponibles(j, disponibles)
  end

  defp aviso_ambos(s, msg) do
    send(s.j1.pid, {:batalla_evento, msg})
    send(s.j2.pid, {:batalla_evento, msg})
  end

  defp mostrar_opciones(s) do
    Enum.each([s.j1, s.j2], fn j ->
      rival = if j.nombre == s.j1.nombre, do: s.j2, else: s.j1

      p_mio = Enum.at(j.pokes, j.activo)
      p_riv = Enum.at(rival.pokes, rival.activo)
      hp_mio = Enum.at(j.hp, j.activo)
      hp_riv = Enum.at(rival.hp, rival.activo)

      msg = """
      \n=== TURNO #{s.turno} ===
      Rival: #{rival.nombre} | #{p_riv.especie} (HP: #{hp_riv}/100)
      Tu Pokémon: #{p_mio.especie} (HP: #{hp_mio}/100)
      Movimientos: 1.#{Enum.at(p_mio.movimientos, 0).nombre} 2.#{Enum.at(p_mio.movimientos, 1).nombre} 3.#{Enum.at(p_mio.movimientos, 2).nombre} 4.#{Enum.at(p_mio.movimientos, 3).nombre}
      """
      send(j.pid, {:batalla_evento, msg})
    end)
  end
end
