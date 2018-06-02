/// Provides an IRC connection to Bancho (osu!'s server system) and access to its commands (Multiplayer room creation)
module bancho.irc;

import core.time;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.datetime.systime;
import std.datetime.timezone;
import std.functional;
import std.path;
import std.string;
import std.typecons;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import vibe.stream.operations;

import tinyevent;

/// Username of BanchoBot (for sending !mp commands & checking source)
static immutable string banchoBotNick = "BanchoBot";

private
{
	auto fixUsername(in char[] username)
	{
		return username.replace(" ", "_");
	}

	auto extractUsername(in char[] part)
	{
		auto i = part.countUntil('!');
		if (i == -1)
			return part[0 .. $];
		else
			return part[1 .. i];
	}

	void sendLine(TCPConnection conn, in char[] line)
	{
		logDebugV("send %s", line);
		conn.write(line);
		conn.write("\r\n");
	}

	void banchoAuthenticate(TCPConnection conn, in char[] username, in char[] password)
	{
		auto fixed = username.fixUsername;
		conn.sendLine("CAP LS 302");
		logDebugV("send PASS ******");
		conn.write("PASS " ~ password ~ "\r\n");
		conn.sendLine("NICK " ~ fixed);
		conn.sendLine("USER " ~ fixed ~ " " ~ fixed ~ " irc.ppy.sh :" ~ fixed);
	}

	void privMsg(TCPConnection conn, in char[] destination, in char[] message)
	{
		conn.sendLine("PRIVMSG " ~ destination ~ " :" ~ message);
	}

	void banchoQuit(TCPConnection conn)
	{
		conn.sendLine("QUIT :Leaving");
	}
}

/// Represents a simple sent message from bancho
struct Message
{
	/// User who wrote this message
	string sender;
	/// Target channel (#channel) or username
	string target;
	/// content of the message
	string message;

	/// Serializes to "[sender] -> [target]: [message]"
	string toString()
	{
		return sender ~ " -> " ~ target ~ ": " ~ message;
	}
}

/// Represents a topic change event (in the case of a multi room being created)
struct TopicChange
{
	///
	string channel, topic;
}

/// Represents a user quitting or joining the IRC ingame or via web/irc
struct Quit
{
	///
	string user;
	/// Mostly one out of:
	/// - "ping timeout 80s"
	/// - "quit"
	/// - "replaced (None 0ea7ac91-60bf-448b-adda-bc6b8d096dc7)"
	/// - "replaced (Supporter c83820bb-a602-43f0-8f17-04718e34b72d)"
	string reason;
}

struct BeatmapInfo
{
	/// b/ ID of the beatmap, extracted from url. Empty if couldn't be parsed
	string id;
	/// URL to the beatmap
	string url;
	/// Artist + Name + Difficulty
	string name;

	/// Parses a map in the format `Ariabl'eyeS - Kegare Naki Bara Juuji (Short ver.) [Rose†kreuz] (https://osu.ppy.sh/b/1239875)`
	static BeatmapInfo parseChange(string map)
	{
		BeatmapInfo ret;
		if (map.endsWith(")"))
		{
			auto start = map.lastIndexOf("(");
			ret.name = map[0 .. start].strip;
			ret.url = map[start + 1 .. $ - 1];
			if (ret.url.startsWith("https://osu.ppy.sh/b/"))
				ret.id = ret.url["https://osu.ppy.sh/b/".length .. $];
		}
		else
			ret.name = map;
		return ret;
	}
}

/// Utility mixin template implementing dynamic timeout based event subscribing + static backlog
/// Creates methods waitFor<fn>, process[fn], fetchOld[fn]Log, clear[fn]Log
mixin template Processor(string fn, Arg, size_t backlog)
{
	struct Backlog
	{
		long at;
		Arg value;
	}

	bool delegate(Arg)[] processors;
	// keep a few around for events called later
	Backlog[backlog] backlogs;

	void process(Arg arg)
	{
		static if (is(typeof(mixin("this.preProcess" ~ fn))))
			mixin("this.preProcess" ~ fn ~ "(arg);");
		foreach_reverse (i, proc; processors)
		{
			if (proc(arg))
			{
				processors[i] = processors[$ - 1];
				processors.length--;
				return;
			}
		}
		auto i = backlogs[].minIndex!"a.at < b.at";
		if (backlogs[i].at != 0)
		{
			static if (is(Arg == Quit))
				logTrace("Disposing " ~ fn ~ " %s", backlogs[i].value);
			else
				logDebugV("Disposing " ~ fn ~ " %s", backlogs[i].value);
		}
		backlogs[i].at = Clock.currStdTime;
		backlogs[i].value = arg;
	}

	Arg waitFor(bool delegate(Arg) check, Duration timeout)
	{
		foreach (ref log; backlogs[].sort!"a.at < b.at")
		{
			if (log.at == 0)
				continue;
			if (check(log.value))
			{
				log.at = 0;
				return log.value;
			}
		}
		if (timeout <= Duration.zero)
			throw new InterruptException();
		Arg ret;
		bool got = false;
		bool delegate(Arg) del = (msg) {
			if (check(msg))
			{
				ret = msg;
				got = true;
				return true;
			}
			return false;
		};
		scope (failure)
			processors = processors.remove!(a => a == del, SwapStrategy.unstable);
		processors ~= del;
		StopWatch sw;
		sw.start();
		while (!got && sw.peek < timeout)
			sleep(10.msecs);
		sw.stop();
		if (!got)
			throw new InterruptException();
		return ret;
	}

	Arg[] fetchOldLog(bool delegate(Arg) check, bool returnIt = true)
	{
		Arg[] ret;
		foreach (ref log; backlogs[].sort!"a.at < b.at")
		{
			if (log.at == 0)
				continue;
			if (check(log.value))
			{
				log.at = 0;
				if (returnIt)
					ret ~= log.value;
			}
		}
		return ret;
	}

	void clearLog()
	{
		backlogs[] = Backlog.init;
		processors.length = 0;
	}

	mixin("alias processors" ~ fn ~ " = processors;");
	mixin("alias backlogs" ~ fn ~ " = backlogs;");
	mixin("alias waitFor" ~ fn ~ " = waitFor;");
	mixin("alias process" ~ fn ~ " = process;");
	mixin("alias fetchOld" ~ fn ~ "Log = fetchOldLog;");
	mixin("alias clear" ~ fn ~ "Log = clearLog;");
}

/// Represents a Bancho IRC connection.
/// Examples:
/// ---
/// BanchoBot bot = new BanchoBot("User", "hunter2");
/// runTask({
///   while (true)
///   {
///     bot.connect();
///     logDiagnostic("Got disconnected from bancho...");
///     sleep(2.seconds);
///   }
/// });
/// ---
class BanchoBot
{
	version (D_Ddoc)
	{
		/// list of event subscribers. Gets removed automatically when called and returns true, otherwise caller has to remove it.
		bool delegate(Message)[] processorsMessage;
		bool delegate(Quit)[] processorsQuit; /// ditto
		bool delegate(TopicChange)[] processorsTopic; /// ditto

		/// list of backlog which hasn't been handled by any event subscribers, oldest one will always be replaced on new ones.
		Message[256] backlogsMessage;
		Quit[256] backlogsQuit; /// ditto
		TopicChange[8] backlogsTopic; /// ditto

		/// Waits for an event or returns one which is in the backlog already. Removes matching backlog entries.
		/// Throws: InterruptException on timeout
		/// Params:
		///   check = a delegate checking for which object to check for. Return true to return this object & not add it to the backlog.
		///   timeout = the timeout after which to interrupt the waiting task
		Message waitForMessage(bool delegate(Message) check, Duration timeout);
		/// ditto
		Quit waitForQuit(bool delegate(Quit) check, Duration timeout);
		/// ditto
		TopicChange waitForTopic(bool delegate(TopicChange) check, Duration timeout);

		/// Calls all event subscribers to try to match this object, otherwise replace the oldest element in the backlog with this.
		/// Throws: anything thrown in event subscribers will get thrown here too.
		void processMessage(Message message);
		/// ditto
		void processQuit(Quit quit);
		/// ditto
		void processTopic(TopicChange change);

		/// Goes through the backlog and removes and optionally returns all matching objects.
		/// Params:
		///   check = a delegate checking for which object to check for. Return true to return this object & removing it from the backlog.
		///   returnIt = pass true to return the list of objects (GC), pass false to simply return an empty list and only remove from the backlog.
		Message[] fetchOldMessageLog(bool delegate(Message) check, bool returnIt = true);
		/// ditto
		Quit[] fetchOldQuitLog(bool delegate(Quit) check, bool returnIt = true);
		/// ditto
		TopicChange[] fetchOldTopicLog(bool delegate(TopicChange) check, bool returnIt = true);

		/// Clears all backlog & removes all event listeners for the object type.
		void clearMessageLog();
		/// ditto
		void clearQuitLog();
		/// ditto
		void clearTopicLog();
	}
	else
	{
		mixin Processor!("Message", Message, 256);
		mixin Processor!("Quit", Quit, 256);
		mixin Processor!("Topic", TopicChange, 8);
	}

	///
	OsuRoom[] rooms;
	///
	TCPConnection client;
	/// Credentials to use for authentication when connecting.
	string username, password;
	/// IRC host to connect to.
	string host;
	/// IRC port to use to connect.
	ushort port;

	/// Prepares a bancho IRC connection with username & password (can be obtained from https://osu.ppy.sh/p/irc)
	this(string username, string password, string host = "irc.ppy.sh", ushort port = 6667)
	{
		if (!password.length)
			throw new Exception("Password can't be empty");
		this.username = username;
		this.password = password;
		this.host = host;
		this.port = port;
	}

	/// Clears all logs, called by connect
	void clear()
	{
		clearMessageLog();
		clearTopicLog();
		clearQuitLog();
	}

	/// Connects to `this.host:this.port` (irc.ppy.sh:6667) and authenticates with username & password. Blocks and processes all messages sent by the TCP socket. Recommended to be called in runTask.
	/// Cleans up on exit properly and is safe to be called again once returned.
	void connect()
	{
		clear();

		client = connectTCP(host, port);
		client.banchoAuthenticate(username, password);
		try
		{
			while (client.connected)
			{
				if (!client.waitForData)
					break;
				char[] line = cast(char[]) client.readLine(1024, "\n");
				if (line.endsWith('\r'))
					line = line[0 .. $ - 1];
				logTrace("recv %s", line);
				auto parts = line.splitter(' ');
				size_t eaten = 0;
				auto user = parts.front;
				if (user == "PING")
				{
					line[1] = 'O'; // P[I]NG -> P[O]NG;
					client.sendLine(line);
					continue;
				}
				eaten += parts.front.length + 1;
				parts.popFront;
				auto cmd = parts.front;
				eaten += parts.front.length + 1;
				parts.popFront;
				if (isNumeric(cmd))
				{
					string lineDup = line.idup;
					runTask(&processNumeric, cmd.to!int, lineDup, lineDup[eaten .. $]);
				}
				else if (cmd == "QUIT")
					runTask(&processQuit, Quit(user.extractUsername.idup, line[eaten + 1 .. $].idup));
				else if (cmd == "PRIVMSG")
				{
					auto target = parts.front;
					eaten += parts.front.length + 1;
					parts.popFront;
					if (line[eaten] != ':')
						throw new Exception("Malformed message received: " ~ line.idup);
					runTask(&processMessage, Message(user.extractUsername.idup,
							target.idup, line[eaten + 1 .. $].idup));
				}
				else
					logDiagnostic("Unknown line %s", line.idup);
			}
		}
		catch (Exception e)
		{
			logError("Exception in IRC task: %s", e);
		}
		if (client.connected)
			client.banchoQuit();
		client.close();
	}

	~this()
	{
		disconnect();
	}

	/// Disconnects & closes the TCP socket.
	void disconnect()
	{
		if (client.connected)
		{
			client.banchoQuit();
			client.close();
		}
	}

	/// Processes messages meant for mutliplayer rooms to update their state.
	/// called by mixin template
	void preProcessMessage(Message message)
	{
		foreach (room; rooms)
			if (room.open && message.target == room.channel)
				runTask((OsuRoom room, Message message) { room.onMessage.emit(message); }, room, message);
		if (message.sender != banchoBotNick)
			return;
		foreach (room; rooms)
		{
			if (room.open && message.target == room.channel)
			{
				try
				{
					if (message.message == "All players are ready")
					{
						runTask((OsuRoom room) { room.onPlayersReady.emit(); }, room);
						foreach (ref slot; room.slots)
							if (slot != OsuRoom.Settings.Player.init)
								slot.ready = true;
						break;
					}
					if (message.message == "Countdown finished")
					{
						runTask((OsuRoom room) { room.onCountdownFinished.emit(); }, room);
						break;
					}
					if (message.message == "Host is changing map...")
					{
						runTask((OsuRoom room) { room.onBeatmapPending.emit(); }, room);
						break;
					}
					if (message.message == "The match has started!")
					{
						runTask((OsuRoom room) { room.onMatchStart.emit(); }, room);
						break;
					}
					if (message.message == "The match has finished!")
					{
						room.processMatchFinish();
						break;
					}
					if (message.message.startsWith("Beatmap changed to: "))
					{
						// Beatmap changed to: Ariabl'eyeS - Kegare Naki Bara Juuji (Short ver.) [Rose†kreuz] (https://osu.ppy.sh/b/1239875)
						room.onBeatmapChanged.emit(BeatmapInfo.parseChange(
								message.message["Beatmap changed to: ".length .. $]));
						break;
					}
					if (message.message.startsWith("Changed match to size "))
					{
						room.processSize(message.message["Changed match to size ".length .. $].strip.to!ubyte);
						break;
					}
					if (message.message.endsWith(" left the game."))
					{
						room.processLeave(message.message[0 .. $ - " left the game.".length]);
						break;
					}
					if (message.message.endsWith(" changed to Blue"))
					{
						room.processTeam(message.message[0 .. $ - " changed to Blue.".length], Team.Blue);
						break;
					}
					if (message.message.endsWith(" changed to Red"))
					{
						room.processTeam(message.message[0 .. $ - " changed to Red.".length], Team.Red);
						break;
					}
					if (message.message.endsWith(" became the host."))
					{
						room.processHost(message.message[0 .. $ - " became the host.".length]);
						break;
					}
					size_t index;
					if ((index = message.message.indexOf(" joined in slot ")) != -1)
					{
						if (message.message.endsWith("."))
							message.message.length--;
						room.processJoin(message.message[0 .. index],
								cast(ubyte)(message.message[index + " joined in slot ".length .. $].to!ubyte - 1));
						break;
					}
					if ((index = message.message.indexOf(" moved to slot ")) != -1)
					{
						if (message.message.endsWith("."))
							message.message.length--;
						room.processMove(message.message[0 .. index],
								cast(ubyte)(message.message[index + " moved to slot ".length .. $].to!int - 1));
						break;
					}
					if ((index = message.message.indexOf(" finished playing (Score: ")) != -1)
					{
						string user = message.message[0 .. index];
						long score = message.message[index
							+ " finished playing (Score: ".length .. $ - ", PASSED).".length].to!long;
						bool pass = message.message.endsWith("PASSED).");
						room.processFinishPlaying(user, score, pass);
						break;
					}
					if (message.message == "Closed the match")
					{
						room.processClosed();
						break;
					}
					break;
				}
				catch (Exception e)
				{
					if (!room.fatal)
					{
						room.sendMessage(
								"An internal exception occurred: " ~ e.msg ~ " in "
								~ e.file.baseName ~ ":" ~ e.line.to!string);
						room.fatal = true;
						logError("%s", e);
					}
					break;
				}
			}
		}
	}

	void processNumeric(int num, string line, string relevantPart)
	{
		// internal function processing numeric commands
		if (num == 332)
		{
			// :cho.ppy.sh 332 WebFreak #mp_40121420 :multiplayer game #24545
			auto parts = relevantPart.splitter(' ');
			size_t eaten;
			if (parts.empty || parts.front != username)
			{
				logInfo("Received topic change not made for us?!");
				return;
			}
			eaten += parts.front.length + 1;
			parts.popFront;
			if (parts.empty)
			{
				logInfo("Received topic change not made for us?!");
				return;
			}
			string channel = parts.front;
			eaten += parts.front.length + 1;
			parts.popFront;
			if (parts.empty || !parts.front.length || parts.front[0] != ':')
			{
				logInfo("Malformed topic change");
				return;
			}
			processTopic(TopicChange(channel, relevantPart[eaten + 1 .. $]));
		}
		else
			logDebug("Got Numeric: %s %s", num, line);
	}

	/// Sends a message to a username or channel (#channel).
	void sendMessage(string channel, in char[] message)
	{
		client.privMsg(channel, message.replace("\n", " "));
	}

	/// Waits for multiple messages sent at once and returns them.
	/// Params:
	///   check = delegate to check if the message matches expectations (author, channel, etc)
	///   timeout = timeout to wait for first message
	///   totalTimeout = total time to spend starting waiting for messages
	///   inbetweenTimeout = timeout for a message after the first message. totalTimeout + inbetweenTimeout is the maximum amount of time this function runs.
	Message[] waitForMessageBunch(bool delegate(Message) check, Duration timeout,
			Duration totalTimeout = 5.seconds, Duration inbetweenTimeout = 300.msecs)
	{
		Message[] ret;
		try
		{
			StopWatch sw;
			sw.start();
			scope (exit)
				sw.stop();
			ret ~= waitForMessage(check, timeout);
			while (sw.peek < totalTimeout)
				ret ~= waitForMessage(check, inbetweenTimeout);
		}
		catch (InterruptException)
		{
		}
		return ret;
	}

	/// Creates a new managed room with a title and returns it.
	/// Automatically gets room ID & game ID.
	OsuRoom createRoom(string title)
	{
		sendMessage(banchoBotNick, "!mp make " ~ title);
		auto msg = this.waitForMessage(a => a.sender == banchoBotNick
				&& a.target == username && a.message.endsWith(" " ~ title), 10.seconds).message;
		if (!msg.length)
			return null;
		// "Created the tournament match https://osu.ppy.sh/mp/40080950 bob"
		if (msg.startsWith("Created the tournament match "))
			msg = msg["Created the tournament match ".length .. $];
		msg = msg[0 .. $ - title.length - 1];
		if (msg.startsWith("https://osu.ppy.sh/mp/"))
			msg = msg["https://osu.ppy.sh/mp/".length .. $];
		msg = "#mp_" ~ msg;
		auto topic = this.waitForTopic(a => a.channel == msg
				&& a.topic.startsWith("multiplayer game #"), 500.msecs).topic;
		auto room = new OsuRoom(this, msg, topic["multiplayer game #".length .. $]);
		rooms ~= room;
		return room;
	}

	/// Joins a room in IRC and creates the room object from it.
	/// Params:
	///     room = IRC Room name (starting with `#mp_`) where to send the messages in.
	///     game = optional string containing the osu://mp/ URL.
	OsuRoom fromUnmanaged(string room, string game = null)
	in
	{
		assert(room.startsWith("#mp_"));
	}
	do
	{
		client.sendLine("JOIN " ~ room);
		auto obj = new OsuRoom(this, room, game);
		rooms ~= obj;
		return obj;
	}

	/// internal function to remove a room from the managed rooms list
	void unmanageRoom(OsuRoom room)
	{
		rooms = rooms.remove!(a => a == room, SwapStrategy.unstable);
	}
}

/*
>> :WebFreak!cho@ppy.sh JOIN :#mp_40121420
<< WHO #mp_40121420
>> :BanchoBot!cho@cho.ppy.sh MODE #mp_40121420 +v WebFreak
>> :cho.ppy.sh 332 WebFreak #mp_40121420 :multiplayer game #24545
>> :cho.ppy.sh 333 WebFreak #mp_40121420 BanchoBot!BanchoBot@cho.ppy.sh 1518796852
>> :cho.ppy.sh 353 WebFreak = #mp_40121420 :@BanchoBot +WebFreak 
>> :cho.ppy.sh 366 WebFreak #mp_40121420 :End of /NAMES list.
>> :BanchoBot!cho@ppy.sh PRIVMSG WebFreak :Created the tournament match https://osu.ppy.sh/mp/40121420 bob
>> :cho.ppy.sh 324 WebFreak #mp_40121420 +nt
>> :cho.ppy.sh 329 WebFreak #mp_40121420 1518796852
>> :cho.ppy.sh 315 WebFreak #mp_40121420 :End of /WHO list.
<< PRIVMSG #mp_40121420 :!mp close
>> :WebFreak!cho@ppy.sh PART :#mp_40121420
>> :BanchoBot!cho@ppy.sh PRIVMSG #mp_40121420 :Closed the match
*/

/*
<WebFreak> !mp invite WebFreak
<BanchoBot> Invited WebFreak to the room
<BanchoBot> WebFreak joined in slot 1.
<BanchoBot> WebFreak moved to slot 2

<WebFreak> !mp host WebFreak
<BanchoBot> WebFreak became the host.
<BanchoBot> Changed match host to WebFreak
<BanchoBot> Beatmap changed to: bibuko - Reizouko Mitara Pudding ga Nai [Mythol's Pudding] (https://osu.ppy.sh/b/256839)

<WebFreak> !mp mods FI
<BanchoBot> Enabled FadeIn, disabled FreeMod

<WebFreak> !mp start
<BanchoBot> The match has started!
<BanchoBot> Started the match
<BanchoBot> WebFreak finished playing (Score: 487680, FAILED).
<BanchoBot> The match has finished!

aborting (esc):
<BanchoBot> WebFreak finished playing (Score: 300, PASSED).

<BanchoBot> WebFreak finished playing (Score: 113216, PASSED).
<BanchoBot> The match has finished!

<BanchoBot> All players are ready

<WebFreak> !mp start
<BanchoBot> The match has started!
<BanchoBot> Started the match

<WebFreak> !mp abort
<BanchoBot> Aborted the match

<BanchoBot> WebFreak moved to slot 3
<BanchoBot> WebFreak changed to Red
<BanchoBot> WebFreak changed to Blue
<BanchoBot> WebFreak moved to slot 1

<BanchoBot> Host is changing map...
<BanchoBot> Beatmap changed to: Aitsuki Nakuru - Krewrap no uta [Easy] (https://osu.ppy.sh/b/1292635)

<WebFreak> !mp settings
<BanchoBot> Room name: bob, History: https://osu.ppy.sh/mp/40081206
<BanchoBot> Beatmap: https://osu.ppy.sh/b/1292635 Aitsuki Nakuru - Krewrap no uta [Easy]
<BanchoBot> Team mode: HeadToHead, Win condition: Score
<BanchoBot> Active mods: Freemod
<BanchoBot> Players: 1
<BanchoBot> Slot 1  Not Ready https://osu.ppy.sh/u/1756786 WebFreak        [Host / Hidden]

<WebFreak> !mp settings
<BanchoBot> Room name: bob, History: https://osu.ppy.sh/mp/40081206
<BanchoBot> Beatmap: https://osu.ppy.sh/b/1292635 Aitsuki Nakuru - Krewrap no uta [Easy]
<BanchoBot> Team mode: HeadToHead, Win condition: Score
<BanchoBot> Active mods: HalfTime, Freemod
<BanchoBot> Players: 1
<BanchoBot> Slot 1  Not Ready https://osu.ppy.sh/u/1756786 WebFreak        [Host / Hidden, HardRock, SuddenDeath]

<WebFreak> !mp size 1
<BanchoBot> WebFreak left the game.
<BanchoBot> Changed match to size 1
<BanchoBot> WebFreak joined in slot 1.
*/

///
enum TeamMode
{
	///
	HeadToHead,
	///
	TagCoop,
	///
	TeamVs,
	///
	TagTeamVs
}

///
enum ScoreMode
{
	///
	Score,
	///
	Accuracy,
	///
	Combo,
	///
	ScoreV2
}

///
enum Team
{
	/// default, used when mode is not TeamVs/TagTeamVs
	None,
	///
	Red,
	///
	Blue
}

///
enum Mod : string
{
	///
	Easy = "Easy",
	///
	NoFail = "NoFail",
	///
	HalfTime = "HalfTime",
	///
	HardRock = "HardRock",
	///
	SuddenDeath = "SuddenDeath",
	///
	DoubleTime = "DoubleTime",
	///
	Nightcore = "Nightcore",
	///
	Hidden = "Hidden",
	///
	FadeIn = "FadeIn",
	///
	Flashlight = "Flashlight",
	///
	Relax = "Relax",
	///
	Autopilot = "Relax2",
	///
	SpunOut = "SpunOut",
	///
	Key1 = "Key1",
	///
	Key2 = "Key2",
	///
	Key3 = "Key3",
	///
	Key4 = "Key4",
	///
	Key5 = "Key5",
	///
	Key6 = "Key6",
	///
	Key7 = "Key7",
	///
	Key8 = "Key8",
	///
	Key9 = "Key9",
	///
	KeyCoop = "KeyCoop",
	///
	ManiaRandom = "Random",
	///
	FreeMod = "FreeMod",
}

/// Generates the short form for a mod (eg Hidden -> HD), can be more than 2 characters
string shortForm(Mod mod)
{
	//dfmt off
	switch (mod)
	{
	case Mod.Easy: return "EZ";
	case Mod.NoFail: return "NF";
	case Mod.HalfTime: return "HT";
	case Mod.HardRock: return "HR";
	case Mod.SuddenDeath: return "SD";
	case Mod.DoubleTime: return "DT";
	case Mod.Nightcore: return "NC";
	case Mod.Hidden: return "HD";
	case Mod.FadeIn: return "FI";
	case Mod.Flashlight: return "FL";
	case Mod.Relax: return "RX";
	case Mod.Autopilot: return "AP";
	case Mod.SpunOut: return "SO";
	case Mod.Key1: return "K1";
	case Mod.Key2: return "K2";
	case Mod.Key3: return "K3";
	case Mod.Key4: return "K4";
	case Mod.Key5: return "K5";
	case Mod.Key6: return "K6";
	case Mod.Key7: return "K7";
	case Mod.Key8: return "K8";
	case Mod.Key9: return "K9";
	case Mod.KeyCoop: return "COOP";
	case Mod.ManiaRandom: return "RN";
	case Mod.FreeMod:
	default: return mod;
	}
	//dfmt on
}

///
alias HighPriority = Flag!"highPriority";

/// Represents a multiplayer lobby in osu!
/// Automatically does ratelimiting by not sending more than a message every 2 seconds.
///
/// All slot indices are 0 based.
class OsuRoom // must be a class, don't change it
{
	/// Returned by !mp settings
	struct Settings
	{
		/// Represents a player state in the settings result
		struct Player
		{
			/// Player user information, may not be there except for name
			string id, url, name;
			///
			bool ready;
			///
			bool playing;
			///
			bool noMap;
			///
			bool host;
			/// If freemods is enabled this contains user specific mods
			Mod[] mods;
			///
			Team team;
		}

		/// Game name
		string name;
		/// URL to match history
		string history;
		/// Beatmap information
		BeatmapInfo beatmap;
		/// Global active mods or all mods if freemods is off, contains Mod.FreeMod if on
		Mod[] activeMods;
		/// Type of game (coop, tag team, etc.)
		TeamMode teamMode;
		/// Win condition (score, acc, combo, etc.)
		ScoreMode winCondition;
		/// Number of players in this match
		int numPlayers;
		/// All players for every slot (empty slots are Player.init)
		Player[16] players;
	}

	private BanchoBot bot;
	private string _channel, id;
	private bool open;
	private SysTime lastMessage;
	private bool fatal;

	/// Automatically managed state of player slots, empty slots are Player.init
	Settings.Player[16] slots;
	/// username as argument
	Event!string onUserLeave;
	/// username & team as argument
	Event!(string, Team) onUserTeamChange;
	/// username as argument
	Event!string onUserHost;
	/// username + slot (0 based) as argument
	Event!(string, ubyte) onUserJoin;
	/// username + slot (0 based) as argument
	Event!(string, ubyte) onUserMove;
	/// emitted when all players are ready
	Event!() onPlayersReady;
	/// Match has started
	Event!() onMatchStart;
	/// Match has ended (all players finished)
	Event!() onMatchEnd;
	/// Host is changing beatmap
	Event!() onBeatmapPending;
	/// Host changed map
	Event!BeatmapInfo onBeatmapChanged;
	/// A message by anyone has been sent
	Event!Message onMessage;
	/// A timer finished
	Event!() onCountdownFinished;
	/// A user finished playing. username + score + passed
	Event!(string, long, bool) onPlayerFinished;
	/// The room has been closed
	Event!() onClosed;

	private this(BanchoBot bot, string channel, string id)
	{
		assert(channel.startsWith("#mp_"));
		lastMessage = Clock.currTime(UTC());
		this.bot = bot;
		this._channel = channel;
		this.id = id;
		open = true;
	}

	ref Settings.Player slot(int index)
	{
		if (index < 0 || index >= 16)
			throw new Exception("slot index out of bounds");
		return slots[index];
	}

	bool hasPlayer(string name)
	{
		foreach (ref slot; slots)
			if (slot.name == name)
				return true;
		return false;
	}

	ref Settings.Player playerByName(string name)
	{
		foreach (ref slot; slots)
			if (slot.name == name)
				return slot;
		throw new Exception("player " ~ name ~ " not found!");
	}

	ref Settings.Player playerByName(string name, out size_t index)
	{
		foreach (i, ref slot; slots)
			if (slot.name == name)
			{
				index = i;
				return slot;
			}
		throw new Exception("player " ~ name ~ " not found!");
	}

	ubyte playerSlotByName(string name)
	{
		foreach (i, ref slot; slots)
			if (slot.name == name)
				return cast(ubyte) i;
		throw new Exception("player " ~ name ~ " not found!");
	}

	/// Returns the channel name as on IRC
	string channel() const @property
	{
		return _channel;
	}

	/// Returns the room ID as usable in the mp history URL or IRC joinable via #mp_ID
	string room() const @property
	{
		return channel["#mp_".length .. $];
	}

	/// Returns the game ID as usable in osu://mp/ID urls
	string mpid() const @property
	{
		return id;
	}

	/// Closes the room
	void close()
	{
		if (!open)
			return;
		sendMessage("!mp close");
		open = false;
	}

	/// Invites a player to the room
	void invite(string player)
	{
		sendMessage("!mp invite " ~ player.fixUsername);
	}

	/// Kicks a player from the room
	void kick(string player)
	{
		sendMessage("!mp kick " ~ player.fixUsername);
	}

	/// Moves a player to another slot
	void move(string player, int slot)
	{
		sendMessage("!mp move " ~ player.fixUsername ~ " " ~ (slot + 1).to!string);
	}

	/// Gives host to a player
	void host(string player) @property
	{
		sendMessage("!mp host " ~ player.fixUsername);
	}

	/// Makes nobody host (make it system/bog managed)
	void clearhost()
	{
		sendMessage("!mp clearhost");
	}

	/// Property to lock slots (disallow changing slots & joining)
	void locked(bool locked) @property
	{
		sendMessage(locked ? "!mp lock" : "!mp unlock");
	}

	/// Sets the match password (password will be visible to existing players)
	void password(string pw) @property
	{
		sendMessage("!mp password " ~ pw);
	}

	/// Changes a user's team
	void setTeam(string user, Team team)
	{
		sendMessage("!mp team " ~ user.fixUsername ~ " " ~ team.to!string);
	}

	/// Changes the slot limit of this lobby
	void size(ubyte slots) @property
	{
		sendMessage("!mp size " ~ slots.to!string);
	}

	/// Sets up teammode, scoremode & lobby size
	void set(TeamMode teammode, ScoreMode scoremode, ubyte size)
	{
		sendMessage("!mp set " ~ (cast(int) teammode)
				.to!string ~ " " ~ (cast(int) scoremode).to!string ~ " " ~ size.to!string);
	}

	/// Changes the mods in this lobby (pass FreeMod first if you want FreeMod)
	void mods(Mod[] mods) @property
	{
		sendMessage("!mp mods " ~ mods.map!(a => a.shortForm).join(" "));
	}

	/// Changes the map to a beatmap ID (b/ url)
	void map(string id) @property
	{
		sendMessage("!mp map " ~ id);
	}

	/// Sets a timer using !mp timer
	void setTimer(Duration d)
	{
		sendMessage("!mp timer " ~ d.total!"seconds".to!string);
	}

	/// Waits for a player to join the room & return the username
	/// Throws: InterruptException if timeout triggers
	string waitForJoin(Duration timeout)
	{
		auto l = bot.waitForMessage(a => a.target == channel && a.sender == banchoBotNick
				&& a.message.canFind(" joined in slot "), timeout).message;
		auto i = l.indexOf(" joined in slot ");
		return l[0 .. i];
	}

	/// Waits for an existing timer/countdown to finish (wont start one)
	/// Throws: InterruptException if timeout triggers
	void waitForTimer(Duration timeout)
	{
		bot.waitForMessage(a => a.target == channel && a.sender == banchoBotNick
				&& a.message == "Countdown finished", timeout);
	}

	/// Aborts any running countdown
	void abortTimer()
	{
		sendMessage("!mp aborttimer");
	}

	/// Aborts a running match
	void abortMatch()
	{
		sendMessage("!mp abort");
	}

	/// Starts a match after a specified amount of seconds. If after is <= 0 the game will be started immediately.
	/// The timeout can be canceled using abortTimer.
	void start(Duration after = Duration.zero)
	{
		if (after <= Duration.zero)
			sendMessage("!mp start");
		else
			sendMessage("!mp start " ~ after.total!"seconds".to!string);
	}

	/// Manually wait until you can send a message again
	void ratelimit(HighPriority highPriority = HighPriority.no)
	{
		auto now = Clock.currTime(UTC());
		auto len = highPriority ? 1200.msecs : 2.seconds;
		while (now - lastMessage < len)
		{
			sleep(len - (now - lastMessage));
			now = Clock.currTime(UTC());
		}
		lastMessage = now;
	}

	/// Sends a message with a 2 second ratelimit
	/// Params:
	///   message = raw message to send
	///   highPriority = if yes, already send after a 1.2 second ratelimit (before others)
	void sendMessage(in char[] message, HighPriority highPriority = HighPriority.no)
	{
		if (!open)
			throw new Exception("Attempted to send message in closed room");
		ratelimit(highPriority);
		bot.sendMessage(channel, message);
	}

	/// Returns the current mp settings
	Settings settings() @property
	{
		int step = 0;
	Retry:
		bot.fetchOldMessageLog(a => a.target == channel && a.sender == banchoBotNick, false);
		sendMessage("!mp settings");
		auto msgs = bot.waitForMessageBunch(a => a.target == channel
				&& a.sender == banchoBotNick, 10.seconds, 10.seconds, 400.msecs);
		if (!msgs.length)
			return Settings.init;
		Settings settings;
		settings.numPlayers = -1;
		int foundPlayers;
		SettingsLoop: foreach (msg; msgs)
		{
			if (msg.message.startsWith("Room name: "))
			{
				// Room name: bob, History: https://osu.ppy.sh/mp/40123558
				msg.message = msg.message["Room name: ".length .. $];
				auto end = msg.message.indexOf(", History: ");
				if (end != -1)
				{
					settings.name = msg.message[0 .. end];
					settings.history = msg.message[end + ", History: ".length .. $];
				}
			}
			else if (msg.message.startsWith("Beatmap: "))
			{
				// Beatmap: https://osu.ppy.sh/b/972293 Ayane - FaV -F*** and Vanguard- [Normal]
				msg.message = msg.message["Beatmap: ".length .. $];
				auto space = msg.message.indexOf(" ");
				if (space != -1)
				{
					settings.beatmap.url = msg.message[0 .. space];
					if (settings.beatmap.url.startsWith("https://osu.ppy.sh/b/"))
						settings.beatmap.id = settings.beatmap.url["https://osu.ppy.sh/b/".length .. $];
					else
						settings.beatmap.id = "";
					settings.beatmap.name = msg.message[space + 1 .. $];
				}
			}
			else if (msg.message.startsWith("Team mode: "))
			{
				// Team mode: TeamVs, Win condition: ScoreV2
				msg.message = msg.message["Team mode: ".length .. $];
				auto comma = msg.message.indexOf(", Win condition: ");
				if (comma != -1)
				{
					settings.teamMode = msg.message[0 .. comma].to!TeamMode;
					settings.winCondition = msg.message[comma + ", Win condition: ".length .. $]
						.to!ScoreMode;
				}
			}
			else if (msg.message.startsWith("Active mods: "))
			{
				// Active mods: Hidden, DoubleTime
				settings.activeMods = msg.message["Active mods: ".length .. $].splitter(", ")
					.map!(a => cast(Mod) a).array;
			}
			else if (msg.message.startsWith("Players: "))
			{
				// Players: 1
				settings.numPlayers = msg.message["Players: ".length .. $].to!int;
			}
			else if (msg.message.startsWith("Slot "))
			{
				foundPlayers++;
				// Slot 1  Not Ready https://osu.ppy.sh/u/1756786 WebFreak        [Host / Team Blue / Hidden, HardRock]
				// Slot 1  Ready     https://osu.ppy.sh/u/1756786 WebFreak        [Host / Team Blue / NoFail, Hidden, HardRock]
				//"Slot 1  Not Ready https://osu.ppy.sh/u/1756786 WebFreak        "
				if (msg.message.length < 63)
					continue;
				auto num = msg.message[5 .. 7].strip.to!int;
				msg.message = msg.message.stripLeft;
				if (num >= 1 && num <= 16)
				{
					auto index = num - 1;
					settings.players[index].ready = msg.message[8 .. 17] == "Ready    ";
					settings.players[index].noMap = msg.message[8 .. 17] == "No Map   ";
					settings.players[index].url = msg.message[18 .. $];
					auto space = settings.players[index].url.indexOf(' ');
					if (space == -1)
						continue;
					auto rest = settings.players[index].url[space + 1 .. $];
					settings.players[index].url.length = space;
					settings.players[index].id = settings.players[index].url[settings.players[index].url.lastIndexOf(
							'/') + 1 .. $];
					auto bracket = rest.indexOf("[", 16);
					if (bracket == -1)
						settings.players[index].name = rest.stripRight;
					else
					{
						settings.players[index].name = rest[0 .. bracket].stripRight;
						auto extra = rest[bracket + 1 .. $];
						if (extra.endsWith("]"))
							extra.length--;
						foreach (part; extra.splitter(" / "))
						{
							if (part == "Host")
								settings.players[index].host = true;
							else if (part.startsWith("Team "))
								settings.players[index].team = part["Team ".length .. $].strip.to!Team;
							else
								settings.players[index].mods = part.splitter(", ").map!(a => cast(Mod) a).array;
						}
					}
				}
			}
		}
		if ((foundPlayers < settings.numPlayers || settings.numPlayers == -1) && ++step < 5)
		{
			msgs = bot.waitForMessageBunch(a => a.target == channel
					&& a.sender == banchoBotNick, 3.seconds, 3.seconds, 600.msecs);
			if (msgs.length)
				goto SettingsLoop;
		}
		if (foundPlayers && settings.numPlayers <= 0 && step < 5)
			goto Retry;
		if (settings.numPlayers == -1)
			return settings;
		slots = settings.players;
		return settings;
	}

	/// Processes a user leave event & updates the state
	void processLeave(string user)
	{
		try
		{
			playerByName(user) = Settings.Player.init;
			runTask({ onUserLeave.emit(user); });
		}
		catch (Exception)
		{
		}
	}

	/// Processes a user team switch event & updates the state
	void processTeam(string user, Team team)
	{
		try
		{
			playerByName(user).team = team;
			runTask({ onUserTeamChange.emit(user, team); });
		}
		catch (Exception)
		{
		}
	}

	/// Processes a user host event & updates the state
	void processHost(string user)
	{
		foreach (ref slot; slots)
			slot.host = false;
		try
		{
			playerByName(user).host = true;
			runTask({ onUserHost.emit(user); });
		}
		catch (Exception)
		{
		}
	}

	/// Processes a user join event & updates the state
	void processJoin(string user, ubyte slot)
	{
		this.slot(slot) = Settings.Player(null, null, user);
		runTask({ onUserJoin.emit(user, slot); });
	}

	/// Processes a user move event & updates the state
	void processMove(string user, ubyte slot)
	{
		if (this.slot(slot) != Settings.Player.init)
			throw new Exception("slot was occupied");
		size_t old;
		this.slot(slot) = playerByName(user, old);
		this.slot(cast(int) old) = Settings.Player.init;
		runTask({ onUserMove.emit(user, slot); });
	}

	/// Processes a room size change event & updates the state
	void processSize(ubyte numSlots)
	{
		foreach (i; numSlots + 1 .. 16)
			if (slots[i] != Settings.Player.init)
			{
				runTask((string user) { onUserLeave.emit(user); }, slots[i].name);
				slots[i] = Settings.Player.init;
			}
	}

	/// Processes a match end event & updates the state
	void processMatchFinish()
	{
		foreach (ref slot; slots)
			if (slot != Settings.Player.init)
				slot.playing = false;
		runTask({ onMatchEnd.emit(); });
	}

	/// Processes a user finish playing event & updates the state
	void processFinishPlaying(string player, long score, bool pass)
	{
		playerByName(player).playing = false;
		runTask({ onPlayerFinished.emit(player, score, pass); });
	}

	/// Processes a room closed event
	void processClosed()
	{
		open = false;
		bot.unmanageRoom(this);
		runTask({ onClosed.emit(); });
	}
}

///
unittest
{
	BanchoBot banchoConnection = new BanchoBot("WebFreak", "");
	bool running = true;
	auto botTask = runTask({
		while (running)
		{
			banchoConnection.connect();
			logDiagnostic("Got disconnected from bancho...");
			sleep(2.seconds);
		}
	});
	sleep(3.seconds);
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
	running = false;
	banchoConnection.disconnect();
	botTask.join();
}
