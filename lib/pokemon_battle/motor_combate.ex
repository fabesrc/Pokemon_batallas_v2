defmodule PokemonBattle.MotorCombate do
  # Tabla de tipos: quien le gana a quien
  @ventajas %{
    "Fuego"     => ["Planta", "Hielo", "Bicho"],
    "Agua"      => ["Fuego", "Roca", "Tierra"],
    "Planta"    => ["Agua", "Roca", "Tierra"],
    "Eléctrico" => ["Agua", "Volador"],
    "Roca"      => ["Fuego", "Hielo", "Volador", "Bicho"]
  }

  # Calcula que tan fuerte es un golpe contra los tipos del otro
  def efectividad(tipo_mov, tipos_defensor) when is_list(tipos_defensor) do
    Enum.reduce(tipos_defensor, 1.0, fn t_def, acc ->
      acc * mod_tipo(tipo_mov, t_def)
    end)
  end

  defp mod_tipo(tipo_mov, tipo_def) do
    # Sacamos quienes son fuertes contra el defensor
    debilidades = for {atk, lista} <- @ventajas, tipo_def in lista, do: atk

    case {tipo_def in Map.get(@ventajas, tipo_mov, []), tipo_mov in debilidades} do
      {true, _} -> 2.0  # Super efectivo
      {_, true} -> 0.5  # Poco efectivo
      _         -> 1.0  # Normal
    end
  end

  # Bono si el pokemon usa un ataque de su mismo tipo
  def stab(tipo_mov, tipos_pkm) do
    if tipo_mov in tipos_pkm, do: 1.5, else: 1.0
  end

  # formula de daño
  def calcular_dano(mov, atk, defen, tipos_atk, tipos_def) do
    # Daño base (simplificado)
    base = trunc(mov.poder_base * (atk.ataque / defen.defensa) / 5 + 2)

    ef = efectividad(mov.tipo, tipos_def)
    st = stab(mov.tipo, tipos_atk)

    # Factor random
    rand = (85 + :rand.uniform(16) - 1) / 100

    final = trunc(base * ef * st * rand)
    if final < 1, do: 1, else: final
  end

  # Quien ataca primero
  def orden_turno(v1, v2) do
    cond do
      v1 > v2 -> :j1_primero
      v2 > v1 -> :j2_primero
      true    -> if :rand.uniform(2) == 1, do: :j1_primero, else: :j2_primero
    end
  end

  # Sistema de sobres y rarezas
  def sortear_rareza(probabilidades) do
    n = :rand.uniform(100)
    e = probabilidades["epico"]
    r = probabilidades["raro"]

    cond do
      n <= e     -> "epico"
      n <= e + r -> "raro"
      true       -> "comun"
    end
  end

  def sortear_factor_rareza(rareza) do
    {min, max} = case rareza do
      "comun" -> {2, 8}
      "raro"  -> {10, 20}
      "epico" -> {25, 40}
    end
    min + :rand.uniform(max - min + 1) - 1
  end

  def aplicar_factor(base, factor), do: round(base * (1 + factor / 100))

  # Mensajes de la consola
  def texto_efectividad(ef) when ef >= 2.0, do: "¡Es muy eficaz!"
  def texto_efectividad(ef) when ef <= 0.5, do: "No es muy eficaz..."
  def texto_efectividad(_), do: ""
end
