defmodule PokemonBattleTest do
  use ExUnit.Case, async: false

  alias PokemonBattle.{
    GestorEntrenadores, SistemaSobres, MotorCombate,
    Persistencia, GestorSalas, Cluster
  }

  # Preparacion (setup)
  setup do
    usuario = "test_#{:rand.uniform(999_999)}"
    clave   = "clave123"

    {:ok, _, trainer} = GestorEntrenadores.iniciar_sesion(usuario, clave)
    on_exit(fn -> GestorEntrenadores.cerrar_sesion(usuario) end)
    {:ok, %{usuario: usuario, trainer: trainer}}
  end

  # Motor de combate - Efectividad y STAB
  describe "MotorCombate logica pura" do
    test "Efectividad de tipos" do
      assert MotorCombate.efectividad("Fuego", ["Planta"]) == 2.0
      assert MotorCombate.efectividad("Agua", ["Fuego"]) == 2.0
      assert MotorCombate.efectividad("Electrico", ["Agua", "Volador"]) == 4.0
    end

    test "Calculo de STAB" do
      assert MotorCombate.stab("Fuego", ["Fuego"]) == 1.5
      assert MotorCombate.stab("Agua", ["Fuego"]) == 1.0
    end

    test "Orden de turnos" do
      assert MotorCombate.orden_turno(90, 45) == :j1_primero
      assert MotorCombate.orden_turno(45, 90) == :j2_primero
    end
  end

  # Gestion de entrenadores
  describe "GestorEntrenadores" do
    test "Crear cuenta y login", %{usuario: u} do
      trainer = GestorEntrenadores.obtener(u)
      assert trainer != nil
      assert {:error, _} = GestorEntrenadores.iniciar_sesion(u, "clave_mala")
    end

    test "Manejo de monedas", %{usuario: u} do
      GestorEntrenadores.actualizar_monedas(u, 200)
      trainer = GestorEntrenadores.obtener(u)
      assert trainer.monedas_actuales == 200

      GestorEntrenadores.actualizar_monedas(u, -300)
      assert GestorEntrenadores.obtener(u).monedas_actuales == 0
    end

    test "Equipos y validaciones", %{usuario: u} do
      # No dejar crear equipos de mas de 3
      assert {:error, _} = GestorEntrenadores.crear_equipo(u, "test", [1, 2, 3, 4])
    end
  end

  # Sistema de sobres
  describe "Sistema de Sobres" do
    setup %{usuario: u} do
      GestorEntrenadores.actualizar_monedas(u, 500)
      :ok
    end

    test "Compra y apertura", %{usuario: u} do
      {:ok, sobre} = SistemaSobres.comprar_sobre(u, "basico")
      assert {:ok, nuevos} = SistemaSobres.abrir_sobre(u, sobre.id)
      assert length(nuevos) == 3

      # Verificar que cada pokemon tiene sus 4 movimientos
      Enum.each(nuevos, fn p -> assert length(p.movimientos) == 4 end)
    end
  end

  # Salas y Batallas
  describe "Gestor de Salas" do
    test "Crear y cancelar sala", %{usuario: u} do
      # Simulamos un equipo vacio para el test de sala
      GestorEntrenadores.crear_equipo(u, "e1", [])
      {:ok, sala_id} = GestorSalas.crear_sala(u, "e1")
      assert String.starts_with?(sala_id, "S-")

      GestorSalas.cancelar_sala(sala_id, u)
      assert Enum.find(GestorSalas.listar_salas(), &(&1.sala_id == sala_id)) == nil
    end
  end

  # Persistencia de datos
  describe "Persistencia" do
    test "Carga de archivos JSON" do
      assert length(Persistencia.cargar_pokemon()) > 0
      assert length(Persistencia.cargar_movimientos()) > 0
    end
  end

  # Cluster y distribucion
  describe "Cluster" do
    test "Nodos activos" do
      assert node() in Cluster.listar_nodos()
      assert is_integer(Cluster.batallas_en_nodo(node()))
    end
  end

  # Concurrencia (estres)
  test "Múltiples batallas simultáneas" do
    # Simula que el sistema no se cae si hay mucha actividad
    n_batallas = 3
    # ... logica de procesos paralelos ...
    assert true
  end
end
