defmodule Taxi.UserManagerTest do
  use ExUnit.Case
  alias Taxi.UserManager

  setup do
    # Limpia el estado antes de cada test
    :sys.replace_state(UserManager, fn _ -> %{} end)
    :ok
  end

  describe "register/3" do
    test "registra un nuevo usuario cliente exitosamente" do
      assert {:ok, user} = UserManager.register("test_client", :client, "password123")
      assert user.username == "test_client"
      assert user.role == :client
      assert user.score == 0
      assert user.streak == 0
    end

    test "registra un nuevo usuario conductor exitosamente" do
      assert {:ok, user} = UserManager.register("test_driver", :driver, "pass456")
      assert user.username == "test_driver"
      assert user.role == :driver
    end

    test "falla al registrar un usuario duplicado" do
      assert {:ok, _} = UserManager.register("duplicate", :client, "pass")
      assert {:error, :user_already_exists} = UserManager.register("duplicate", :client, "pass2")
    end
  end

  describe "login/2" do
    test "login exitoso con credenciales correctas" do
      UserManager.register("user1", :client, "mypass")
      assert {:ok, user} = UserManager.login("user1", "mypass")
      assert user.username == "user1"
    end

    test "falla con contraseña incorrecta" do
      UserManager.register("user2", :client, "correct")
      assert {:error, :invalid_password} = UserManager.login("user2", "wrong")
    end

    test "falla con usuario inexistente" do
      assert {:error, :user_not_found} = UserManager.login("noexiste", "pass")
    end
  end

  describe "add_score/2" do
    test "suma puntos correctamente" do
      UserManager.register("scorer", :client, "pass")
      UserManager.add_score("scorer", 10)
      assert UserManager.get_score("scorer") == 10

      UserManager.add_score("scorer", 5)
      assert UserManager.get_score("scorer") == 15
    end

    test "resta puntos correctamente" do
      UserManager.register("penalty", :client, "pass")
      UserManager.add_score("penalty", 20)
      UserManager.add_score("penalty", -5)
      assert UserManager.get_score("penalty") == 15
    end

    test "permite puntajes negativos" do
      UserManager.register("negative", :client, "pass")
      UserManager.add_score("negative", -10)
      assert UserManager.get_score("negative") == -10
    end
  end

  describe "streak system" do
    test "incrementa racha sin bono (< 3 viajes)" do
      UserManager.register("streaker1", :driver, "pass")
      assert {:ok, 0} = UserManager.increment_streak("streaker1")
      assert UserManager.get_streak("streaker1") == 1

      assert {:ok, 0} = UserManager.increment_streak("streaker1")
      assert UserManager.get_streak("streaker1") == 2
    end

    test "otorga bono de 5 pts en racha de 3" do
      UserManager.register("streaker3", :driver, "pass")
      UserManager.increment_streak("streaker3")
      UserManager.increment_streak("streaker3")
      assert {:ok, 5} = UserManager.increment_streak("streaker3")
      assert UserManager.get_streak("streaker3") == 3
      assert UserManager.get_score("streaker3") == 5
    end

    test "otorga bono de 10 pts en racha de 5" do
      UserManager.register("streaker5", :driver, "pass")
      Enum.each(1..4, fn _ -> UserManager.increment_streak("streaker5") end)
      assert {:ok, 10} = UserManager.increment_streak("streaker5")
      assert UserManager.get_streak("streaker5") == 5
    end

    test "otorga bono de 25 pts en racha de 10" do
      UserManager.register("streaker10", :driver, "pass")
      Enum.each(1..9, fn _ -> UserManager.increment_streak("streaker10") end)
      assert {:ok, 25} = UserManager.increment_streak("streaker10")
      assert UserManager.get_streak("streaker10") == 10
    end

    test "reset_streak reinicia la racha a 0" do
      UserManager.register("resetter", :driver, "pass")
      Enum.each(1..5, fn _ -> UserManager.increment_streak("resetter") end)
      assert UserManager.get_streak("resetter") == 5

      UserManager.reset_streak("resetter")
      assert UserManager.get_streak("resetter") == 0
    end
  end

  describe "ranking/1" do
    test "retorna ranking ordenado por puntaje" do
      UserManager.register("user1", :client, "p")
      UserManager.register("user2", :driver, "p")
      UserManager.register("user3", :client, "p")

      UserManager.add_score("user1", 100)
      UserManager.add_score("user2", 200)
      UserManager.add_score("user3", 50)

      ranking = UserManager.ranking(10)
      assert length(ranking) == 3
      assert Enum.at(ranking, 0).username == "user2"
      assert Enum.at(ranking, 1).username == "user1"
      assert Enum.at(ranking, 2).username == "user3"
    end

    test "respeta el límite especificado" do
      Enum.each(1..5, fn i ->
        UserManager.register("user#{i}", :client, "p")
        UserManager.add_score("user#{i}", i * 10)
      end)

      ranking = UserManager.ranking(3)
      assert length(ranking) == 3
    end
  end

  describe "ranking_by_role/2" do
    test "filtra solo clientes" do
      UserManager.register("client1", :client, "p")
      UserManager.register("driver1", :driver, "p")
      UserManager.register("client2", :client, "p")

      UserManager.add_score("client1", 50)
      UserManager.add_score("driver1", 100)
      UserManager.add_score("client2", 75)

      ranking = UserManager.ranking_by_role(:client, 10)
      assert length(ranking) == 2
      assert Enum.all?(ranking, fn u -> u.role == :client end)
      assert Enum.at(ranking, 0).username == "client2"
    end

    test "filtra solo conductores" do
      UserManager.register("client1", :client, "p")
      UserManager.register("driver1", :driver, "p")
      UserManager.register("driver2", :driver, "p")

      UserManager.add_score("driver1", 200)
      UserManager.add_score("driver2", 150)

      ranking = UserManager.ranking_by_role(:driver, 10)
      assert length(ranking) == 2
      assert Enum.all?(ranking, fn u -> u.role == :driver end)
    end
  end

  describe "get_user_role/1" do
    test "retorna el rol correcto del usuario" do
      UserManager.register("client", :client, "p")
      UserManager.register("driver", :driver, "p")

      assert UserManager.get_user_role("client") == :client
      assert UserManager.get_user_role("driver") == :driver
    end

    test "retorna nil para usuario inexistente" do
      assert UserManager.get_user_role("noexiste") == nil
    end
  end
end
