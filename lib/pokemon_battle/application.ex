defmodule PokemonBattle.Application do
  use Application

  def start(_type, _args) do
    children = [
      # registry para buscar las batallas
      {Registry, keys: :unique, name: PokemonBattle.Registry},

      # Los gestores
      PokemonBattle.GestorEntrenadores,
      PokemonBattle.GestorSalas,
      PokemonBattle.GestorTrades,

      # Supervisores dinamicos
      {DynamicSupervisor, name: PokemonBattle.SupBatallas, strategy: :one_for_one},
      {DynamicSupervisor, name: PokemonBattle.SupIntercambios, strategy: :one_for_one}
    ]


    Supervisor.start_link(children, strategy: :one_for_one, name: PokemonBattle.CheckSup)
  end
end
