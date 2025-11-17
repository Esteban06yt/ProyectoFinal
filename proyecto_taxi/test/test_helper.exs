ExUnit.start()

# Helper para limpiar archivos de prueba
defmodule TestHelper do
  def cleanup_test_files do
    File.rm_rf!("data/test_users.json")
    File.rm_rf!("data/test_results.json")
    File.rm_rf!("data/test_locations.json")
  end

  def create_test_user(username, role \\ :client, password \\ "test123") do
    Taxi.UserManager.register(username, role, password)
  end

  def wait_for_trip_state(trip_id, expected_state, timeout \\ 5000) do
    wait_until(timeout, fn ->
      try do
        info = Taxi.Trip.list_info(trip_id)
        info["state"] == expected_state
      rescue
        _ -> false
      end
    end)
  end

  defp wait_until(0, _fun), do: false
  defp wait_until(timeout, fun) do
    if fun.() do
      true
    else
      Process.sleep(100)
      wait_until(timeout - 100, fun)
    end
  end
end
