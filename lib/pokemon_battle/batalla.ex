defmodule PokemonBattle.Batalla do
  use GenServer, restart: :temporary
  alias PokemonBattle.{MotorCombate, GestorEntrenadores, Persistencia}

  @t_turno 20_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:sala_id]))
  end

  def via(id), do: {:via, Registry, {PokemonBattle.Registry, {:batalla, id}}}

  # API
  def accion(id, user, act), do: GenServer.cast(via(id), {:accion, user, act})
  def cambiar_pokemon(id, user, idx), do: GenServer.cast(via(id), {:cambio, user, idx})

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
      timer: nil,
      status: :jugando,
      reemplazos: [],
      nodo: opts[:nodo] || node()
    }

    # Primer aviso
    aviso_ambos(state, "--- Batalla Iniciada! ---")
    mostrar_opciones(state)

    {:ok, %{state | timer: iniciar_timer()}}
  end

  @impl true
  def handle_cast({:accion, user, act}, state) do
    # evitar que un jugador mueva dos veces o mueva fuera de tiempo
    if state.status != :jugando or Map.has_key?(state.acts, user) do
      {:noreply, state}
    else
      new_acts = Map.put(state.acts, user, act)

      if map_size(new_acts) == 2 do
        # Si ambos movieron, procesamos como siempre
        Process.cancel_timer(state.timer)
        {:noreply, procesar_turno(%{state | acts: new_acts})}
      else
        # quién es el jugador actual y quién es el rival
        {p_actual, p_rival} = j_y_rival(state, user)

        send(p_actual.pid, {:batalla_evento, "Esperando a que #{p_rival.nombre} elija su movimiento..."})

        send(p_rival.pid, {:batalla_evento, "¡#{user} ya está listo! Es tu turno."})

        {:noreply, %{state | acts: new_acts}}
      end
    end
  end

  @impl true
  def handle_cast({:cambio, user, idx}, state) do
    if user in state.reemplazos do
      j = get_j(state, user)
      # Cambiar el índice del pokemon activo
      nuevo_j = %{j | activo: idx}
      state = set_j(state, nuevo_j)

      restantes = List.delete(state.reemplazos, user)
      if restantes == [] do
        {:noreply, nuevo_turno(%{state | reemplazos: []})}
      else
        {:noreply, %{state | reemplazos: restantes}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    # Si alguien no movió, pasa
    acts = state.acts
    |> Map.put_new(state.j1.nombre, "pasar")
    |> Map.put_new(state.j2.nombre, "pasar")

    {:noreply, procesar_turno(%{state | acts: acts})}
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
    {atk, defen} = j_y_rival(s, nom_atk)
    p_atk = Enum.at(atk.pokes, atk.activo)
    p_def = Enum.at(defen.pokes, defen.activo)

    mov_idx = case Integer.parse(s.acts[nom_atk] || "") do
      {num, _} -> num - 1
      :error -> 0
    end

    mov = Enum.at(p_atk.movimientos, mov_idx) || hd(p_atk.movimientos)


    dano = MotorCombate.calcular_dano(
      mov,
      p_atk,
      p_def,
      atk.tipos[p_atk.especie],
      defen.tipos[p_def.especie]
    )

    # aplicar daño al hp
    nueva_hp = max(0, Enum.at(defen.hp, defen.activo) - dano)
    defen = %{defen | hp: List.replace_at(defen.hp, defen.activo, nueva_hp)}

    aviso_ambos(s, "#{nom_atk}: #{mov.nombre} hizo #{dano} de daño")
    if nueva_hp == 0, do: aviso_ambos(s, "#{p_def.especie} de #{defen.nombre} se debilitó")

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
          aviso_ambos(s, "Esperando cambios de pokemon...")
          %{s | status: :reemplazo, reemplazos: muertos}
        end
    end
  end

  defp nuevo_turno(s) do
    s = %{s | turno: s.turno + 1, status: :jugando}
    mostrar_opciones(s)
    %{s | timer: iniciar_timer()}
  end

  defp terminar(s, ganador) do
    aviso_ambos(s, "FIN: Ganador #{ganador}")

    if ganador != :empate do
      # quien es el perdedor
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

  defp iniciar_timer, do: Process.send_after(self(), :timeout, @t_turno)

  defp get_j(s, nom), do: if(s.j1.nombre == nom, do: s.j1, else: s.j2)
  defp set_j(s, j), do: if(s.j1.nombre == j.nombre, do: %{s | j1: j}, else: %{s | j2: j})
  defp j_y_rival(s, nom), do: if(s.j1.nombre == nom, do: {s.j1, s.j2}, else: {s.j2, s.j1})
  defp tiene_hp?(j), do: Enum.at(j.hp, j.activo) > 0

  defp aviso_ambos(s, msg) do
    send(s.j1.pid, {:batalla_evento, msg})
    send(s.j2.pid, {:batalla_evento, msg})
  end

  defp mostrar_opciones(s) do
    p1 = Enum.at(s.j1.pokes, s.j1.activo)
    p2 = Enum.at(s.j2.pokes, s.j2.activo)
    hp1 = Enum.at(s.j1.hp, s.j1.activo)
    hp2 = Enum.at(s.j2.hp, s.j2.activo)

    msg = """
    \n=== TURNO #{s.turno} ===
    Rival: #{s.j2.nombre} | #{p2.especie} (HP: #{hp2}/100)
    Tu Pokémon: #{p1.especie} (HP: #{hp1}/100)
    Movimientos: 1.#{Enum.at(p1.movimientos, 0).nombre} 2.#{Enum.at(p1.movimientos, 1).nombre}...
    """
    aviso_ambos(s, msg)
  end
end
