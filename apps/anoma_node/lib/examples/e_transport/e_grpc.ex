defmodule Anoma.Node.Examples.EGRPC do
  @moduledoc """
  I contain examples to test the GRPC endpoint of the node.
  """
  use TypedStruct

  alias Anoma.Node.Examples.EGRPC
  alias Anoma.Node.Examples.ENode
  alias Anoma.Protobuf.Intents.Add
  alias Anoma.Protobuf.Intents.Intent
  alias Anoma.Protobuf.Intents.List
  alias Anoma.Protobuf.IntentsService

  import ExUnit.Assertions

  require Logger

  ############################################################
  #                    Context                               #
  ############################################################

  typedstruct do
    @typedoc """
    I am the state of a GRPC connection to the node.

    ### Fields
    - `:channel` - The channel for making grpc requests.
    """
    field(:channel, any())
  end

  @doc """
  Given an enode, I connect to its GRPC endpoint.

  The examples in this file are used to test against the client GRPC endpoint.
  The client needs a node to process incoming requests (except prove), so a node is also required
  to run these examples.
  """
  @spec connect_to_node(ENode.t() | nil) :: EGRPC.t()
  def connect_to_node(enode \\ nil) do
    # if no node was given, this ran in a unit test.
    # we kill all nodes since we can only have a local node for this test.
    enode =
      if enode == nil do
        ENode.kill_all_nodes()
        ENode.start_node(grpc_port: 0)
      else
        enode
      end

    result =
      case GRPC.Stub.connect("localhost:#{enode.grpc_port}") do
        {:ok, channel} ->
          %EGRPC{channel: channel}

        {:error, reason} ->
          Logger.error("GRPC connection failed: #{inspect(reason)}")
          {:error, reason}
      end

    assert Kernel.match?(%EGRPC{}, result)

    result
  end

  @doc """
  I list the intents over grpc on the client.
  """
  @spec list_intents(EGRPC.t()) :: boolean()
  def list_intents(%EGRPC{} = client \\ connect_to_node()) do
    request = %List.Request{}

    {:ok, reply} = IntentsService.Stub.list_intents(client.channel, request)

    assert reply.intents == []
  end

  @doc """
  I add an intent to the client.
  """
  @spec add_intent(EGRPC.t()) :: boolean()
  def add_intent(%EGRPC{} = client \\ connect_to_node()) do
    request = %Add.Request{
      intent: %Intent{value: 1}
    }

    {:ok, _reply} = IntentsService.Stub.add_intent(client.channel, request)

    # fetch the intents to ensure it was added
    request = %List.Request{}

    {:ok, reply} = IntentsService.Stub.list_intents(client.channel, request)

    assert reply.intents == ["1"]
  end
end
