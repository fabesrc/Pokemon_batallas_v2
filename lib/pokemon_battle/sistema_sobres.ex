defmodule PokemonBattle.SistemaSobres do
  alias PokemonBattle.{GestorEntrenadores, MotorCombate, Persistencia}

  # Comprar

  def comprar_sobre(usuario, tipo_sobre) do
    tienda = Persistencia.cargar_tienda()
    # Buscamos el sobre en la tienda
    config = Enum.find(tienda, fn s -> s["tipo"] == tipo_sobre end)

    if config == nil do
      {:error, "Ese sobre no existe"}
    else
      precio = config["precio"]
      trainer = GestorEntrenadores.obtener(usuario)

      if trainer.monedas_actuales < precio do
        {:error, "No tienes dinero suficiente"}
      else
        # Restamos el dinero y guardamos el sobre en la cuenta
        GestorEntrenadores.actualizar_monedas(usuario, -precio)
        nuevo_sobre = %{id: generar_id(), tipo: tipo_sobre}
        GestorEntrenadores.agregar_sobre(usuario, nuevo_sobre)
        {:ok, nuevo_sobre}
      end
    end
  end

  # Abrir

  def abrir_sobre(usuario, "ultimo") do
    trainer = GestorEntrenadores.obtener(usuario)
    if trainer.sobres_pendientes == [] do
      {:error, "No tienes nada que abrir"}
    else
      sobre = List.last(trainer.sobres_pendientes)
      abrir_sobre(usuario, sobre.id)
    end
  end

  def abrir_sobre(usuario, sobre_id) do
    # Convertir a entero si viene como string
    id = if is_binary(sobre_id), do: String.to_integer(sobre_id), else: sobre_id

    trainer = GestorEntrenadores.obtener(usuario)
    sobre = Enum.find(trainer.sobres_pendientes, &(&1.id == id))

    if sobre == nil do
      {:error, "Sobre no encontrado"}
    else
      tienda = Persistencia.cargar_tienda()
      config = Enum.find(tienda, &(&1["tipo"] == sobre.tipo))

      # cargamos los catalogos
      pokes_base = Persistencia.cargar_pokemon()
      moves_base = Persistencia.cargar_movimientos()

      # gGeneramos los 3 pokemon
      nuevos = for _ <- 1..3 do
        crear_pokemon(usuario, pokes_base, moves_base, config["probabilidades"])
      end

      # Actualizamos al entrenador
      GestorEntrenadores.quitar_sobre(usuario, id)
      Enum.each(nuevos, fn p -> GestorEntrenadores.agregar_pokemon(usuario, p) end)

      {:ok, nuevos}
    end
  end

  # Generacion de Pokemon

  defp crear_pokemon(dueno, pokes_base, moves_base, probs) do
    base = Enum.random(pokes_base)
    rareza = MotorCombate.sortear_rareza(probs)
    factor = MotorCombate.sortear_factor_rareza(rareza)

    # Calculamos stats con el factor de rareza
    at = MotorCombate.aplicar_factor(base["ataque_base"], factor)
    df = MotorCombate.aplicar_factor(base["defensa_base"], factor)
    vl = MotorCombate.aplicar_factor(base["velocidad_base"], factor)

    %{
      id: generar_id(),
      especie: base["especie"],
      dueno_original: dueno,
      rareza: rareza,
      ataque: at,
      defensa: df,
      velocidad: vl,
      movimientos: elegir_movimientos(base["tipos"], moves_base)
    }
  end

  # Logica para los 4 ataques
  defp elegir_movimientos(tipos_pkm, catalogo) do
    # 1. Separar ataques que coinciden con el tipo del pokemon
    propios = Enum.filter(catalogo, fn m -> m["tipo"] in tipos_pkm end)
    # 2. El resto de ataques
    otros = Enum.filter(catalogo, fn m -> m["tipo"] not in tipos_pkm end)

    # Elegimos 2 del tipo del pokemon y 2 aleatorios del resto
    movs = Enum.take(Enum.shuffle(propios), 2) ++ Enum.take(Enum.shuffle(otros), 2)

    # Limpiamos el mapa para que solo tenga lo que necesitamos
    Enum.map(movs, fn m ->
      %{nombre: m["nombre"], tipo: m["tipo"], poder_base: m["poder_base"]}
    end)
  end

  defp generar_id, do: :rand.uniform(899_999) + 100_000
end
