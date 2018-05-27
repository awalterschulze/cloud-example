# cloud haskell example

This example sends a sequence of random numbers between nodes using the [cloud-haskell](http://haskell-distributed.github.io/) framework.

## How

The master spawns one process on each node, which it initializes with a sorted list of the process ids.

The first process in the list of process ids elects itself as the leader and starts sending a random number to each of the processes.
The random number is used to select the next leader.
The current leader knows this and can make sure to first send the random number to all other followers in parallel.
When all followers received the random number the current leader can send the number to the next leader.
This way the sequence of random numbers is guaranteed.

When the sending time expires, the master sends a shutdown signal to all processes.
All processes simply store this channel, but the next leader sends its own shutdown signal to a processes.
When a process has received both shutdown signals, it prints out its result and replies to both channels.
Finally the leader also prints out its result and replies to the master's channel.
This way clean shutdown with empty message queues is achieved.

The result is a tuple: `(length msgs, sum (imap (\index msg -> index * msg) msgs))`

## Running

### Requirements

Please install [stack](https://docs.haskellstack.org/en/stable/README/#how-to-install)

### Testing

Testing allows you to run a full cluster as a unit test:

```
stack build
stack test
```

### Running slave

First start up the slaves in the background:

```
stack exec cloud-example-exe -- --port 4445 &
stack exec cloud-example-exe -- --port 4446 &
stack exec cloud-example-exe -- --port 4447 &
```

### Running master

Next start up the master:

```
stack exec cloud-example-exe -- --master --send-for 10 --wait-for 30 --with-seed 123 --discover
```

This master with tell all slaves to send messages for 10 seconds and then wait for 30 seconds for them to cleanly shutdown.
The seed allows the random numbers to be pseudo randomly generated.
The discover flags can be used instead of hard coding the nodes in `./app/Main.hs` in the `hardcodedAddrs` function.

## Problems

  - Sleeping with threadDelay is sleeping too long.
  - Messages always wait for a reply to make sure they arrived at their destination, this could freeze up the whole system.
  - No restart policies with supervision have been added, which should handle issues when nodes or networks give errors.
  - Not only random numbers are being sent, but there is also an initial message and shutdown messages.
  - Require a minimum of at least two slaves.