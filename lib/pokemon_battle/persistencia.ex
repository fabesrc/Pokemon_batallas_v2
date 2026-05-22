defmodule PokemonBattle.Persistencia do
  # Carpeta donde guardamos los archivos
  @dir "data"

  # Entrenadores
  def cargar_entrenadores do
    leer_archivo("#{@dir}/trainers.json", [])
  end

  def guardar_entrenadores(lista) do
    escribir_archivo("#{@dir}/trainers.json", lista)
  end

  # Catalogos
  def cargar_pokemon, do: leer_archivo("#{@dir}/pokemon.json", [])
  def cargar_movimientos, do: leer_archivo("#{@dir}/moves.json", [])
  def cargar_tienda, do: leer_archivo("#{@dir}/tienda.json", [])

  # Logs de las peleas
  def registrar_batalla(info) do
    # Formato simple, Fecha | Jugadores | Ganador
    fecha = DateTime.utc_now() |> to_string()

    linea = "#{fecha} | #{info.jugador1} vs #{info.jugador2} | Ganó: #{info.ganador} | Turnos: #{info.turnos} | Nodo: #{info.nodo}\n"

    path = "#{@dir}/battles.log"
    # :append es para que no borre lo anterior y escriba al final
    File.write(path, linea, [:append])
  end

  # funciones privadas para leer/escribir

  defp leer_archivo(path, default) do
    case File.read(path) do
      {:ok, contenido} ->
        case Jason.decode(contenido) do
          {:ok, data} -> data
          {:error, _} -> default
        end
      {:error, _} ->
        default
    end
  end

  defp escribir_archivo(path, data) do
    json = Jason.encode!(data, pretty: true)
    File.write!(path, json)
  end
end
