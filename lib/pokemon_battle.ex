defmodule PokemonBattle do
  # guia rapida:
  # 1. Abrir la terminal y poner: iex --sname arena@localhost -S mix
  # 2. Escribir: PokemonBattle.iniciar()
  # 3. Comandos basicos para probar:
  #    - login tu_nombre 1234
  #    - dar_monedas 500
  #    - comprar basico
  #    - abrir
  #    - inventario
  #    - crear_sala nombre_equipo

  def iniciar do
    # Este es el acceso directo al servidor
    PokemonBattle.Servidor.iniciar_sesion()
  end
end
