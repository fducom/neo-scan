defmodule Neoscan.Addresses do
  @moduledoc false
  @moduledoc """
  The boundary for the Addresses system.
  """

  import Ecto.Query, warn: false
  alias Neoscan.Repo
  alias Neoscan.Addresses.Address
  alias Neoscan.BalanceHistories
  alias Neoscan.BalanceHistories.History
  alias Neoscan.Claims
  alias Neoscan.Claims.Claim
  alias Neoscan.Helpers
  alias Ecto.Multi

  @doc """
  Returns the list of addresses.

  ## Examples

      iex> list_addresses()
      [%Address{}, ...]

  """
  def list_addresses do
    from(a in Address, preload: :histories)
    |> Repo.all()
  end

  @doc """
  Gets a single address.

  Raises `Ecto.NoResultsError` if the Address does not exist.

  ## Examples

      iex> get_address!(123)
      %Address{}

      iex> get_address!(456)
      ** (Ecto.NoResultsError)

  """
  def get_address!(id) do
    from(a in Address, where: a.id == ^id, preload: :histories)
    |> Repo.all()
  end
  @doc """
  Gets a single address by its hash and send it as a map

  ## Examples

      iex> get_address_by_hash_for_view(123)
      %{}

      iex> get_address_by_hash_for_view(456)
      nil

  """
  def get_address_by_hash_for_view(hash) do
   his_query = from h in History,
     order_by: [desc: h.block_height],
     select: %{
       txid: h.txid
     }

   claim_query = from h in Claim,
     select: %{
       txids: h.txids
     }
   query = from e in Address,
     where: e.address == ^hash,
     preload: [histories: ^his_query],
     preload: [claimed: ^claim_query],
     select: e #%{:address => e.address, :tx_ids => e.histories, :balance => e.balance, :claimed => e.claimed}
   Repo.all(query)
   |> List.first
  end


  @doc """
  Gets a single address by its hash and send it as a map

  ## Examples

      iex> get_address_by_hash(123)
      %{}

      iex> get_address_by_hash(456)
      nil

  """
  def get_address_by_hash(hash) do

   query = from e in Address,
     where: e.address == ^hash,
     select: e

   Repo.all(query)
   |> List.first
  end

  @doc """
  Creates a address.

  ## Examples

      iex> create_address(%{field: value})
      %Address{}

      iex> create_address(%{field: bad_value})
      no_return

  """
  def create_address(attrs \\ %{}) do
    %Address{}
    |> Address.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Updates a address.

  ## Examples

      iex> update_address(address, %{field: new_value})
      %Address{}

      iex> update_address(address, %{field: bad_value})
      no_return

  """
  def update_address(%Address{} = address, attrs) do
    address
    |> Address.update_changeset(attrs)
    |> Repo.update()
  end

  #updates all addresses in the transactions with their respective changes/inserts
  def update_multiple_addresses(list) do
    list
    |> Enum.map(fn {address, attrs} -> verify_if_claim_and_call_changesets(address, attrs) end)
    |> create_multi
    |> Repo.transaction
    |> check_repo_transaction_results()
  end

  #verify if there was claim operations for the address
  def verify_if_claim_and_call_changesets(address, %{:claimed => claim} = attrs) do
    {address, Claims.change_claim(%Claim{}, address, claim), BalanceHistories.change_history(%History{}, address,  attrs.tx_ids), change_address(address, attrs)}
  end
  def verify_if_claim_and_call_changesets(address, attrs)do
    {address, nil, BalanceHistories.change_history(%History{}, address,  attrs.tx_ids), change_address(address, attrs)}
  end

  #creates new Ecto.Multi sequence for single DB transaction
  def create_multi(changesets) do
    Enum.reduce(changesets, Multi.new, fn (tuple, acc) -> insert_updates(tuple, acc) end)
  end

  #Insert address updates in the Ecto.Multi
  def insert_updates({address,claim_changeset, history_changeset, address_changeset}, acc) do
      name = String.to_atom(address.address)
      name1 = String.to_atom("#{address.address}_history")
      name2 = String.to_atom("#{address.address}_claim")

      acc
      |> Multi.update(name, address_changeset, [])
      |> Multi.insert(name1, history_changeset, [])
      |> Claims.add_claim_if_claim(name2, claim_changeset)
  end

  #verify if DB transaction was sucessfull
  def check_repo_transaction_results({:ok, _any}) do
    {:ok, "all operations were succesfull"}
  end
  def check_repo_transaction_results({:error, error}) do
    IO.inspect(error)
    raise "error updating addresses"
  end


  @doc """
  Deletes a Address.

  ## Examples

      iex> delete_address(address)
      {:ok, %Address{}}

      iex> delete_address(address)
      {:error, %Ecto.Changeset{}}

  """
  def delete_address(%Address{} = address) do
    Repo.delete!(address)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking address changes.

  ## Examples

      iex> change_address(address)
      %Ecto.Changeset{source: %Address{}}

  """
  def change_address(%Address{} = address, attrs) do
    Address.update_changeset(address, attrs)
  end

  @doc """
  Check if address exist in database

  ## Examples

      iex> check_if_exist(existing_address})
      true

      iex> check_if_exist(new_address})
      false

  """
  def check_if_exist(address) do
    query = from e in Address,
      where: e.address == ^address,
      select: e.addres

    case Repo.all(query) |> List.first do
      nil ->
        false
      :string ->
        true
    end
  end

  #get all addresses involved in a transaction
  def get_transaction_addresses(vins, vouts, time) do

    lookups = (Helpers.map_vins(vins) ++ Helpers.map_vouts(vouts)) |> Enum.uniq

    query =  from e in Address,
     where: e.address in ^lookups,
     select: struct(e, [:id, :address, :balance])

     Repo.all(query)
     |> fetch_missing(lookups, time)
     |> Helpers.gen_attrs()
  end

  #create missing addresses
  def fetch_missing(address_list, lookups, time) do
    (lookups -- Enum.map(address_list, fn %{:address => address} -> address end))
    |> Enum.map(fn address -> create_address(%{"address" => address, "time" => time}) end)
    |> Enum.concat(address_list)
  end



  #Update vins and claims into addresses
  def update_all_addresses(address_list,[], nil, _vouts, _txid, _index, _time) do
    address_list
  end
  def update_all_addresses(address_list,[], claims, vouts, _txid, index, time) do
    address_list
    |> Claims.separate_txids_and_insert_claims(claims, vouts, index, time)
  end
  def update_all_addresses(address_list, vins, nil, _vouts, txid, index, time) do
    address_list
    |> group_vins_by_address_and_update(vins, txid, index, time)
  end
  def update_all_addresses(address_list, vins, claims, vouts, txid, index, time) do
    address_list
    |> group_vins_by_address_and_update(vins, txid, index, time)
    |> Claims.separate_txids_and_insert_claims(claims, vouts, index, time)
  end

  #separate vins by address hash, insert vins and update the address
  def group_vins_by_address_and_update(address_list, vins, txid, index, time) do
    updates = Enum.group_by(vins, fn %{:address_hash => address} -> address end)
    |> Map.to_list()
    |> Helpers.populate_groups(address_list)
    |> Enum.map(fn {address, vins} -> insert_vins_in_address(address, vins, txid, index, time) end)


    Enum.map(address_list, fn {address, attrs} -> Helpers.substitute_if_updated(address, attrs, updates) end)
  end

  #insert vins into address balance
  def insert_vins_in_address({address, attrs}, vins, txid, index, time) do
    new_attrs = Map.merge(attrs, %{:balance => Helpers.check_if_attrs_balance_exists(attrs) || address.balance, :tx_ids => Helpers.check_if_attrs_txids_exists(attrs) || %{}})
    |> add_vins(vins)
    |> BalanceHistories.add_tx_id(txid, index, time)
    {address, new_attrs}
  end

  #add multiple vins
  def add_vins(attrs, vins) do
    Enum.reduce(vins, attrs, fn (vin, acc) -> add_vin(acc, vin) end)
  end

  #add a single vin into adress
  def add_vin(%{:balance => balance} = attrs, vin) do
    current_amount = balance[vin.asset]["amount"]
    new_balance = %{"asset" => vin.asset, "amount" => current_amount - vin.value}
    %{attrs | balance: Map.put(attrs.balance || %{}, vin.asset, new_balance)}
  end


end
