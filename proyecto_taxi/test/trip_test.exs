defmodule Taxi.TripTest do
  use ExUnit.Case
  alias Taxi.{Trip, UserManager}

  setup do
    # Limpia usuarios antes de cada test
    :sys.replace_state(UserManager, fn _ -> %{} end)

    # Crea usuarios de prueba
    UserManager.register("test_client", :client, "pass")
    UserManager.register("test_driver", :driver, "pass")

    :ok
  end

  describe "Trip creation and info" do
    test "crea un viaje con información correcta" do
      args = %{
        id: "trip1",
        client: "test_client",
        origin: "Parque",
        destination: "Centro"
      }

      {:ok, pid} = Trip.start_link(args)
      assert Process.alive?(pid)

      info = Trip.list_info("trip1")
      assert info["id"] == "trip1"
      assert info["client"] == "test_client"
      assert info["origin"] == "Parque"
      assert info["destination"] == "Centro"
      assert info["state"] == :waiting
      assert info["driver"] == nil
    end

    test "viaje inicia en estado :waiting" do
      args = %{id: "trip2", client: "test_client", origin: "A", destination: "B"}
      {:ok, _pid} = Trip.start_link(args)

      info = Trip.list_info("trip2")
      assert info["state"] == :waiting
    end
  end

  describe "Trip acceptance" do
    test "conductor puede aceptar viaje en estado waiting" do
      args = %{id: "trip3", client: "test_client", origin: "A", destination: "B"}
      {:ok, _pid} = Trip.start_link(args)

      assert {:ok, "trip3"} = Trip.accept("trip3", "test_driver")

      info = Trip.list_info("trip3")
      assert info["state"] == :in_progress
      assert info["driver"] == "test_driver"
    end

    test "segundo conductor no puede aceptar viaje ya aceptado" do
      UserManager.register("driver2", :driver, "pass")

      args = %{id: "trip4", client: "test_client", origin: "A", destination: "B"}
      {:ok, _pid} = Trip.start_link(args)

      assert {:ok, _} = Trip.accept("trip4", "test_driver")
      assert {:error, :already_accepted} = Trip.accept("trip4", "driver2")
    end

    test "no se puede aceptar viaje completado" do
      args = %{id: "trip5", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      Trip.accept("trip5", "test_driver")

      # Forzar estado completado
      :sys.replace_state(pid, fn state ->
        %{state | state: :completed}
      end)

      assert {:error, :trip_completed} = Trip.accept("trip5", "driver2")
    end
  end

  describe "Trip cancellation" do
    test "cliente puede cancelar su propio viaje en estado waiting" do
      args = %{id: "trip6", client: "test_client", origin: "A", destination: "B"}
      {:ok, _pid} = Trip.start_link(args)

      initial_score = UserManager.get_score("test_client")

      assert {:ok, :cancelled} = Trip.cancel("trip6", "test_client")

      # Verifica penalización
      final_score = UserManager.get_score("test_client")
      assert final_score == initial_score - 3
    end

    test "cliente no puede cancelar viaje de otro usuario" do
      UserManager.register("other_client", :client, "pass")

      args = %{id: "trip7", client: "test_client", origin: "A", destination: "B"}
      {:ok, _pid} = Trip.start_link(args)

      assert {:error, :cannot_cancel} = Trip.cancel("trip7", "other_client")
    end

    test "no se puede cancelar viaje en progreso" do
      args = %{id: "trip8", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      Trip.accept("trip8", "test_driver")

      # Espera a que cambie a in_progress
      Process.sleep(50)

      assert {:error, :cannot_cancel} = Trip.cancel("trip8", "test_client")
    end
  end

  describe "Trip expiration" do
    test "viaje expira después del timeout si no es aceptado" do
      args = %{id: "trip9", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      initial_score = UserManager.get_score("test_client")

      # Simula expiración enviando mensaje directamente
      ref = :sys.get_state(pid).timer_ref
      send(pid, {:expire, ref})

      # Espera a que procese
      Process.sleep(100)

      # Verifica penalización
      final_score = UserManager.get_score("test_client")
      assert final_score == initial_score - 5
    end

    test "viaje no expira si ya fue aceptado" do
      args = %{id: "trip10", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      old_ref = :sys.get_state(pid).timer_ref
      Trip.accept("trip10", "test_driver")

      # Envía mensaje de expiración con referencia vieja
      send(pid, {:expire, old_ref})
      Process.sleep(50)

      # Viaje sigue en progreso
      info = Trip.list_info("trip10")
      assert info["state"] == :in_progress
    end
  end

  describe "Trip completion" do
    test "viaje se completa y otorga puntos correctamente" do
      args = %{id: "trip11", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      client_initial = UserManager.get_score("test_client")
      driver_initial = UserManager.get_score("test_driver")

      Trip.accept("trip11", "test_driver")

      # Simula finalización
      ref = :sys.get_state(pid).timer_ref
      send(pid, {:finish, ref})

      Process.sleep(100)

      # Verifica puntos: cliente +10, conductor +15
      assert UserManager.get_score("test_client") == client_initial + 10
      assert UserManager.get_score("test_driver") >= driver_initial + 15
    end

    test "racha de conductor se incrementa al completar viaje" do
      args = %{id: "trip12", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      initial_streak = UserManager.get_streak("test_driver")

      Trip.accept("trip12", "test_driver")
      ref = :sys.get_state(pid).timer_ref
      send(pid, {:finish, ref})

      Process.sleep(100)

      assert UserManager.get_streak("test_driver") == initial_streak + 1
    end

    test "bono de racha se aplica correctamente (3 viajes)" do
      # Completa 2 viajes primero
      Enum.each(1..2, fn i ->
        args = %{id: "setup#{i}", client: "test_client", origin: "A", destination: "B"}
        {:ok, pid} = Trip.start_link(args)
        Trip.accept("setup#{i}", "test_driver")
        ref = :sys.get_state(pid).timer_ref
        send(pid, {:finish, ref})
        Process.sleep(50)
      end)

      # Tercer viaje debe dar bono
      args = %{id: "bonus_trip", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      score_before = UserManager.get_score("test_driver")

      Trip.accept("bonus_trip", "test_driver")
      ref = :sys.get_state(pid).timer_ref
      send(pid, {:finish, ref})

      Process.sleep(100)

      score_after = UserManager.get_score("test_driver")
      # 15 puntos base + 5 de bono = 20
      assert score_after - score_before == 20
    end
  end

  describe "Edge cases" do
    test "maneja mensajes inesperados sin crashear" do
      args = %{id: "trip13", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      send(pid, :random_message)
      send(pid, {:unknown, "data"})

      Process.sleep(50)

      # Proceso sigue vivo
      assert Process.alive?(pid)
    end

    test "ignora referencias de timer obsoletas" do
      args = %{id: "trip14", client: "test_client", origin: "A", destination: "B"}
      {:ok, pid} = Trip.start_link(args)

      # Envía finish con referencia inventada
      send(pid, {:finish, make_ref()})
      Process.sleep(50)

      # Estado no cambia
      info = Trip.list_info("trip14")
      assert info["state"] == :waiting
    end
  end
end
