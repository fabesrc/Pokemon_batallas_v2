defmodule PokemonBattle.Cluster do
  # Función para conectar con otra PC/Nodo
  def conectar(nodo) when is_binary(nodo), do: conectar(String.to_atom(nodo))

  def conectar(nodo) do
    case Node.connect(nodo) do
      true  -> {:ok, "Listo, conectado a #{nodo}"}
      false -> {:error, "No conectó. Revisa el nombre o la cookie."}
      _     -> {:error, "Nodo no distribuido (usa --sname)"}
    end
  end

  # Ver quien está conectado
  def listar_nodos, do: [node() | Node.list()]

  # Busca cual nodo tiene menos trabajo
  def nodo_menos_cargado do
    nodos = listar_nodos()

    # mapeamos los nodos a su cantidad de batallas y sacamos el menor
    {nodo, _cantidad} =
      Enum.map(nodos, fn n -> {n, conteo_batallas(n)} end)
      |> Enum.min_by(fn {_n, count} -> count end)

    nodo
  end


  defp conteo_batallas(n) do
    if n == node() do
      # En mi nodo local
      DynamicSupervisor.count_children(PokemonBattle.SupervisorBatallas).active
    else
      case :rpc.call(n, DynamicSupervisor, :count_children, [PokemonBattle.SupervisorBatallas]) do
        {:badrpc, _} -> 999 # Si falla el nodo, le ponemos carga infinita
        res -> res.active
      end
    end
  end


  def estado_cluster do
    for n <- listar_nodos() do
      local = if n == node(), do: "(yo)", else: ""
      "#{n} #{local} -> #{conteo_batallas(n)} batallas"
    end |> Enum.join("\n")
  end
end
