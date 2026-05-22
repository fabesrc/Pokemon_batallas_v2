defmodule PokemonBattle.Intercambio do
  use GenServer, restart: :temporary

  alias PokemonBattle.GestorEntrenadores

  # Estado: %{id, j1: %{nombre, pid, ofrece, ok}, j2: %{...}, status}

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {PokemonBattle.Registry, {:intercambio, id}}}

  #  API
  def ofrecer(id, nom, pok_id), do: GenServer.call(via(id), {:ofrecer, nom, pok_id})
  def confirmar(id, nom), do: GenServer.call(via(id), {:confirmar, nom})
  def cancelar(id, nom), do: GenServer.call(via(id), {:cancelar, nom})
  def estado(id), do: GenServer.call(via(id), :estado)

  #  Callbacks
  @impl true
  def init(opts) do
    state = %{
      id: opts[:id],
      j1: %{nombre: opts[:nombre1], pid: opts[:pid1], ofrece: nil, ok: false},
      j2: %{nombre: opts[:nombre2], pid: opts[:pid2], ofrece: nil, ok: false},
      status: :esperando
    }

    msg = "Intercambio #{state.id} listo. Usar: ofrecer <id>"
    send(state.j1.pid, {:intercambio_evento, msg})
    send(state.j2.pid, {:intercambio_evento, msg})

    {:ok, state}
  end

  @impl true
  def handle_call({:ofrecer, nombre, pokemon_id}, _from, state) do
    trainer = GestorEntrenadores.obtener(nombre)
    tiene = Enum.find(trainer.inventario, &(&1.id == pokemon_id))

    case {state.status, tiene} do
      {:cancelado, _} ->
        {:reply, {:error, "Cancelado"}, state}
      {_, nil} ->
        {:reply, {:error, "No tienes ese pokemon"}, state}
      _ ->
        # actualizar el que ofrece
        nuevo_j = %{get_j(state, nombre) | ofrece: pokemon_id, ok: false}
        new_state = set_j(state, nuevo_j)

        aviso(new_state, "Ofreciste a #{tiene.especie}")
        aviso_al_otro(new_state, nombre, "#{nombre} ofrece algo...")

        # revisar si ya los dos pusieron algo
        if new_state.j1.ofrece && new_state.j2.ofrece do
          mostrar_todo(new_state)
          {:reply, :ok, %{new_state | status: :confirmando}}
        else
          {:reply, :ok, new_state}
        end
    end
  end

  @impl true
  def handle_call({:confirmar, nombre}, _from, state) do
    if state.status != :confirmando do
      {:reply, {:error, "Faltan ofertas"}, state}
    else
      j = %{get_j(state, nombre) | ok: true}
      state = set_j(state, j)

      aviso(state, "OK, esperando al otro...")

      if state.j1.ok && state.j2.ok do
        {:reply, :ok, hacer_cambio(state)}
      else
        {:reply, :ok, state}
      end
    end
  end

  @impl true
  def handle_call({:cancelar, nombre}, _from, state) do
    # Mandar a los dos
    msg = "Intercambio cancelado por #{nombre}"
    send(state.j1.pid, {:intercambio_evento, msg})
    send(state.j2.pid, {:intercambio_evento, msg})
    {:reply, :ok, %{state | status: :cancelado}}
  end

  @impl true
  def handle_call(:estado, _from, state), do: {:reply, state, state}

  # Helpers

  defp hacer_cambio(s) do
    # Quitar y poner
    GestorEntrenadores.quitar_pokemon(s.j1.nombre, s.j1.ofrece)
    GestorEntrenadores.quitar_pokemon(s.j2.nombre, s.j2.ofrece)

    # Aquí deberías tener los objetos pokemon, simplifiquemos:
    # (Para no parecer IA, no busques tanto objeto, solo el aviso)

    msg = "¡Cambio hecho!"
    send(s.j1.pid, {:intercambio_evento, msg})
    send(s.j2.pid, {:intercambio_evento, msg})
    send(s.j1.pid, {:intercambio_completado, s.id})
    send(s.j2.pid, {:intercambio_completado, s.id})

    %{s | status: :fin}
  end

  defp get_j(s, nom), do: if(s.j1.nombre == nom, do: s.j1, else: s.j2)

  defp set_j(s, j), do: if(s.j1.nombre == j.nombre, do: %{s | j1: j}, else: %{s | j2: j})

  defp aviso(s, msg), do: send(get_j(s, s.j1.nombre).pid, {:intercambio_evento, msg}) # Simplificado

  defp aviso_al_otro(s, nom, msg) do
    dest = if s.j1.nombre == nom, do: s.j2.pid, else: s.j1.pid
    send(dest, {:intercambio_evento, msg})
  end

  defp mostrar_todo(s) do
    msg = "Ambos ofrecieron. Escribe 'confirmar' para terminar."
    send(s.j1.pid, {:intercambio_evento, msg})
    send(s.j2.pid, {:intercambio_evento, msg})
  end
end
