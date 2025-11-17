defmodule Taxi.ServerTest do
  use ExUnit.Case
  alias Taxi.{Server, UserManager}

  setup do
    # Limpia estado antes de cada test
    :sys.replace_state(UserManager, fn _ -> %{} end)
    :sys.replace_state(Server, fn _ -> %{sessions: %{}, trips: MapSet.new()} end)

    # Limpia registry de viajes
    Registry.select(Taxi.TripRegistry, [{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.each(fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :ok
  end

  describe "connect/4 - login" do
    test "login exitoso con credenciales válidas" do
      UserManager.register("user1", :client, "password123")

      assert {:ok, "user1"} = Server.connect(self(), "user1", nil, "password123")
    end

    test "login falla con contraseña incorrecta" do
      UserManager.register("user2", :client, "correct")

      assert {:error, :invalid_password} = Server.connect(self(), "user2", nil, "wrong")
    end

    test "login falla con usuario inexistente" do
      assert {:error, :user_not_found} = Server.connect(self(), "noexiste", nil, "pass")
    end
  end

  describe "connect/4 - registro" do
    test "registro exitoso de nuevo cliente" do
      assert {:ok, "newclient"} = Server.connect(self(), "newclient", :client, "pass123")

      # Verifica que el usuario existe
      assert UserManager.get_user_role("newclient") == :client
    end

    test "registro exitoso de nuevo conductor" do
      assert {:ok, "newdriver"} = Server.connect(self(), "newdriver", :driver, "pass456")

      assert UserManager.get_user_role("newdriver") == :driver
    end

    test "registro falla si el usuario ya existe" do
      UserManager.register("existing", :client, "pass")

      assert {:error, :user_already_exists} =
        Server.connect(self(), "existing", :client, "otherpass")
    end
  end

  describe "disconnect/1" do
    test "desconecta usuario exitosamente" do
      UserManager.register("user", :client, "pass")
      Server.connect(self(), "user", nil, "pass")

      assert :ok = Server.disconnect(self())
    end
  end

  describe "request_trip/4" do
    setup do
      UserManager.register("client1", :client, "pass")
      :ok
    end

    test "crea viaje exitosamente con ubicaciones válidas" do
      assert {:ok, trip_id} =
        Server.request_trip(self(), "client1", "Parque", "Centro")

      assert is_binary(trip_id)

      # Verifica que el viaje existe
      trips = Server.list_trips()
      assert Enum.any?(trips, fn t -> t["id"] == trip_id end)
    end

    test "rechaza origen inválido" do
      assert {:error, :invalid_origin} =
        Server.request_trip(self(), "client1", "LugarInexistente", "Centro")
    end

    test "rechaza destino inválido" do
      assert {:error, :invalid_destination} =
        Server.request_trip(self(), "client1", "Parque", "DestinoFalso")
    end

    test "rechaza origen y destino iguales" do
      assert {:error, :same_origin_destination} =
        Server.request_trip(self(), "client1", "Parque", "Parque")
    end

    test "rechaza viaje duplicado (mismo origen/destino pendiente)" do
      Server.request_trip(self(), "client1", "Parque", "Centro")

      assert {:error, :trip_already_exists} =
        Server.request_trip(self(), "client1", "Parque", "Centro")
    end

    test "permite múltiples viajes con diferentes destinos" do
      assert {:ok, _} = Server.request_trip(self(), "client1", "Parque", "Centro")
      assert {:ok, _} = Server.request_trip(self(), "client1", "Hospital", "Aeropuerto")
    end

    test "rechaza crear viaje si usuario ya tiene uno activo" do
      {:ok, trip_id} = Server.request_trip(self(), "client1", "Parque", "Centro")

      # Acepta el viaje para que esté en progreso
      UserManager.register("driver1", :driver, "pass")
      Server.accept_trip(self(), trip_id, "driver1")

      assert {:error, :user_has_active_trip} =
        Server.request_trip(self(), "client1", "Hospital", "Museo")
    end
  end

  describe "list_trips/0" do
    test "retorna lista vacía cuando no hay viajes" do
      assert Server.list_trips() == []
    end

    test "retorna solo viajes en estado waiting" do
      UserManager.register("client1", :client, "pass")
      UserManager.register("driver1", :driver, "pass")

      {:ok, trip1} = Server.request_trip(self(), "client1", "Parque", "Centro")
      {:ok, trip2} = Server.request_trip(self(), "client1", "Hospital", "Museo")

      # Acepta uno
      Server.accept_trip(self(), trip1, "driver1")

      trips = Server.list_trips()
      trip_ids = Enum.map(trips, fn t -> t["id"] end)

      # Solo trip2 debe estar en la lista (waiting)
      assert trip2 in trip_ids
      refute trip1 in trip_ids
    end

    test "retorna información correcta de los viajes" do
      UserManager.register("client1", :client, "pass")
      {:ok, trip_id} = Server.request_trip(self(), "client1", "Parque", "Centro")

      trips = Server.list_trips()
      trip = Enum.find(trips, fn t -> t["id"] == trip_id end)

      assert trip["client"] == "client1"
      assert trip["origin"] == "Parque"
      assert trip["destination"] == "Centro"
      assert trip["state"] == :waiting
    end
  end

  describe "accept_trip/3" do
    setup do
      UserManager.register("client1", :client, "pass")
      UserManager.register("driver1", :driver, "pass")
      {:ok, trip_id} = Server.request_trip(self(), "client1", "Parque", "Centro")

      {:ok, trip_id: trip_id}
    end

    test "conductor acepta viaje exitosamente", %{trip_id: trip_id} do
      assert {:ok, ^trip_id} = Server.accept_trip(self(), trip_id, "driver1")

      # Verifica que el viaje tiene conductor
      info = Taxi.Trip.list_info(trip_id)
      assert info["driver"] == "driver1"
      assert info["state"] == :in_progress
    end

    test "rechaza aceptar viaje inexistente" do
      assert {:error, :trip_not_found} =
        Server.accept_trip(self(), "trip_falso", "driver1")
    end

    test "segundo conductor no puede aceptar viaje ya aceptado", %{trip_id: trip_id} do
      UserManager.register("driver2", :driver, "pass")

      Server.accept_trip(self(), trip_id, "driver1")

      assert {:error, :already_accepted} =
        Server.accept_trip(self(), trip_id, "driver2")
    end

    test "conductor con viaje activo no puede aceptar otro", %{trip_id: trip_id} do
      # Acepta el primer viaje
      Server.accept_trip(self(), trip_id, "driver1")

      # Crea segundo viaje
      UserManager.register("client2", :client, "pass")
      {:ok, trip2} = Server.request_trip(self(), "client2", "Hospital", "Museo")

      assert {:error, :user_has_active_trip} =
        Server.accept_trip(self(), trip2, "driver1")
    end
  end

  describe "cancel_trip/2" do
    setup do
      UserManager.register("client1", :client, "pass")
      {:ok, trip_id} = Server.request_trip(self(), "client1", "Parque", "Centro")

      {:ok, trip_id: trip_id}
    end

    test "cliente cancela su viaje exitosamente", %{trip_id: trip_id} do
      initial_score = UserManager.get_score("client1")

      assert {:ok, ^trip_id} = Server.cancel_trip(trip_id, "client1")

      # Verifica penalización
      assert UserManager.get_score("client1") == initial_score - 3
    end

    test "no se puede cancelar viaje de otro usuario", %{trip_id: trip_id} do
      UserManager.register("other_client", :client, "pass")

      assert {:error, :cannot_cancel} = Server.cancel_trip(trip_id, "other_client")
    end

    test "no se puede cancelar viaje en progreso", %{trip_id: trip_id} do
      UserManager.register("driver1", :driver, "pass")
      Server.accept_trip(self(), trip_id, "driver1")

      assert {:error, :cannot_cancel} = Server.cancel_trip(trip_id, "client1")
    end
  end

  describe "my_trips/1" do
    test "retorna viajes del cliente" do
      UserManager.register("client1", :client, "pass")
      UserManager.register("client2", :client, "pass")

      {:ok, trip1} = Server.request_trip(self(), "client1", "Parque", "Centro")
      {:ok, _trip2} = Server.request_trip(self(), "client2", "Hospital", "Museo")

      my_trips = Server.my_trips("client1")
      trip_ids = Enum.map(my_trips, fn t -> t["id"] end)

      assert trip1 in trip_ids
      assert length(my_trips) == 1
    end

    test "retorna viajes del conductor" do
      UserManager.register("client1", :client, "pass")
      UserManager.register("driver1", :driver, "pass")

      {:ok, trip1} = Server.request_trip(self(), "client1", "Parque", "Centro")
      Server.accept_trip(self(), trip1, "driver1")

      driver_trips = Server.my_trips("driver1")
      assert length(driver_trips) == 1
      assert Enum.at(driver_trips, 0)["driver"] == "driver1"
    end

    test "retorna lista vacía si no hay viajes" do
      UserManager.register("client1", :client, "pass")

      assert Server.my_trips("client1") == []
    end
  end

  describe "ranking/0" do
    test "retorna ranking ordenado" do
      UserManager.register("user1", :client, "p")
      UserManager.register("user2", :driver, "p")
      UserManager.register("user3", :client, "p")

      UserManager.add_score("user1", 50)
      UserManager.add_score("user2", 100)
      UserManager.add_score("user3", 25)

      ranking = Server.ranking()

      assert Enum.at(ranking, 0).username == "user2"
      assert Enum.at(ranking, 1).username == "user1"
      assert Enum.at(ranking, 2).username == "user3"
    end
  end

  describe "ranking_by_role/1" do
    test "filtra ranking por rol cliente" do
      UserManager.register("client1", :client, "p")
      UserManager.register("driver1", :driver, "p")
      UserManager.register("client2", :client, "p")

      UserManager.add_score("client1", 50)
      UserManager.add_score("driver1", 100)
      UserManager.add_score("client2", 75)

      ranking = Server.ranking_by_role(:client)

      assert length(ranking) == 2
      assert Enum.all?(ranking, fn u -> u.role == :client end)
    end

    test "filtra ranking por rol conductor" do
      UserManager.register("client1", :client, "p")
      UserManager.register("driver1", :driver, "p")
      UserManager.register("driver2", :driver, "p")

      ranking = Server.ranking_by_role(:driver)

      assert Enum.all?(ranking, fn u -> u.role == :driver end)
    end
  end
end
