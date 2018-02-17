# bancho-irc

[osu!](https://osu.ppy.sh) IRC client library basically only compatible with bancho due to `\n` line endings and very limited IRC commands.

## [Documentation](https://webfreak001.github.io/bancho-irc/index.html)

## Example

```d
auto users = ["WebFreak", "Node"];
OsuRoom room = banchoConnection.createRoom("bob");
runTask({
	foreach (user; users)
		room.invite(user);
});
runTask({
	room.password = "123456";
	room.size = 8;
	room.mods = [Mod.Hidden, Mod.DoubleTime];
	room.map = "1158325";
});
runTask({
	int joined;
	try
	{
		while (true)
		{
			string user = room.waitForJoin(30.seconds);
			joined++;
			room.sendMessage("yay welcome " ~ user ~ "!", HighPriority.yes);
		}
	}
	catch (InterruptException)
	{
		if (joined == 0)
		{
			// forever alone
			room.close();
			return;
		}
	}
	room.sendMessage("This is an automated test, this room will close in 10 seconds on timer");
	room.setTimer(10.seconds);
	try
	{
		room.waitForTimer(15.seconds);
	}
	catch (InterruptException)
	{
		room.sendMessage("Timer didn't trigger :(");
		room.sendMessage("closing the room in 5s");
		sleep(5.seconds);
	}
	room.close();
}).join();
```
