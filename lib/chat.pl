/*  Part of SWISH

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2016, VU University Amsterdam
			 CWI Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(swish_chat,
	  [ chat_broadcast/1,		% +Message
	    chat_broadcast/2,		% +Message, +Channel

	    notifications//1		% +Options
	  ]).
:- use_module(library(http/hub)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_session)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(debug)).
:- use_module(library(broadcast)).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_path)).

:- use_module(storage).
:- use_module(gitty).
:- use_module(config).
:- use_module(avatar).
:- use_module(noble_avatar).

/** <module> The SWISH collaboration backbone

We have three levels of identity as   enumerated  below. Note that these
form a hierarchy: a particular user  may   be  logged  on using multiple
browsers which in turn may have multiple SWISH windows opened.

  1. Any open SWISH window has an associated websocket, represented
     by the identifier returned by hub_add/3.
  2. Any browser, possibly having multiple open SWISH windows, is
     identified by a session cookie.
  3. The user may be logged in, either based on the cookie or on
     HTTP authentication.
*/

:- multifile
	swish_config:config/2.

swish_config:config(chat, true).


		 /*******************************
		 *	ESTABLISH WEBSOCKET	*
		 *******************************/

:- http_handler(swish(chat), start_chat, [ id(swish_chat) ]).

start_chat(Request) :-
	swish_config:authenticate(Request, User), !, % must throw to deny access
	start_chat(Request, [user(User)]).
start_chat(Request) :-
	start_chat(Request, []).

start_chat(Request, Options) :-
	http_session_id(Session),
	http_parameters(Request,
			[ avatar(Avatar, [optional(true)])
			]),
	extend_options([avatar(Avatar)], Options, Options1),
	http_upgrade_to_websocket(
	    accept_chat(Session, Options1),
	    [ guarded(false),
	      subprotocols([chat])
	    ],
	    Request).

extend_options([], Options, Options).
extend_options([H|T0], Options, [H|T]) :-
	ground(H), !,
	extend_options(T0, Options, T).
extend_options([_|T0], Options, T) :-
	extend_options(T0, Options, T).


accept_chat(Session, Options, WebSocket) :-
	create_chat_room,
	hub_add(swish_chat, WebSocket, Id),
	create_visitor(Id, Session, TmpUser, UserData, Options),
	hub_send(Id, json(UserData.put(_{type:welcome, uid:TmpUser}))).


		 /*******************************
		 *	        DATA		*
		 *******************************/

%%	visitor_session(?WSId, ?Session).
%%	session_user(?Session, ?TmpUser).
%%	visitor_data(?TmpUser, ?UserData:dict).
%%	subscription(?Session, ?Channel, ?SubChannel).
%
%	These predicates represent our notion of visitors.
%
%	@arg WSID is the identifier of the web socket. As we may have to
%	reconnect lost connections, this is may be replaced.
%	@arg Session is the session identifier.  This is used to connect
%	SWISH actions to WSIDs.
%	@arg TmpUser is the ID with which we identify the user for this
%	run. The value is a UUID and thus doesn't reveal the real
%	identity of the user.
%	@arg UserDict is a dict that holds information about the real
%	user identity.  This can be empty if no information is known
%	about this user.

:- dynamic
	visitor_session/2,		% WSID, Session
	session_user/2,			% Session, TmpUser
	visitor_data/2,			% TmpUser, Data
	subscription/3.			% WSID, Channel, SubChannel

%%	create_visitor(+WSID, +Session, -TmpUser, -UserData, +Options)
%
%	Create a new visitor. The first   clause  deals with two windows
%	opened from the same  browser  or   re-establishing  a  lost web
%	socket.

create_visitor(WSID, Session, TmpUser, UserData, Options) :-
	(   visitor_session(_, Session)
	->  true
	;   OneDay is 24*60*60,
	    http_set_session(Session, timeout(OneDay))
	),
	assertz(visitor_session(WSID, Session)),
	create_session_user(Session, TmpUser, UserData, Options).

%%	destroy_visitor(+WSID)
%
%	The web socket WSID has been   closed. We should not immediately
%	destroy the temporary user as the browser may soon reconnect due
%	to a page reload  or  re-establishing   the  web  socket after a
%	temporary network failure. We leave   the destruction thereof to
%	the session, but set the session timeout to a fairly short time.
%
%	@tbd	We should only inform clients that we have informed
%		about this user.

destroy_visitor(WSID) :-
	must_be(atom, WSID),
	retract(visitor_session(WSID, Session)),
	(   visitor_session(_, Session)
	->  true
	;   http_set_session(Session, timeout(300)),
	    session_user(Session, UID),
	    Message = _{ type:left,
			 uid:UID
		       },
	    chat_broadcast(Message)
	).

%%	create_session_user(+Session, -User, -UserData, +Options)
%
%	Associate a user with the session. The user id is a UUID that is
%	not associated with  any  persistent  notion   of  a  user.  The
%	destruction is left to the destruction of the session.

:- unlisten(http_session(end(_, _))),
   listen(http_session(end(SessionID, _Peer)),
	  destroy_session_user(SessionID)).

create_session_user(Session, TmpUser, UserData, _Options) :-
	session_user(Session, TmpUser),
	visitor_data(TmpUser, UserData), !.
create_session_user(Session, TmpUser, UserData, Options) :-
	uuid(TmpUser),
	get_visitor_data(UserData, Options),
	assertz(session_user(Session, TmpUser)),
	assertz(visitor_data(TmpUser, UserData)).

destroy_session_user(Session) :-
	retract(session_user(Session, TmpUser)),
	destroy_visitor_data(TmpUser).

destroy_visitor_data(TmpUser) :-
	(   retract(visitor_data(TmpUser, Data)),
	    release_avatar(Data.get(avatar)),
	    fail
	;   true
	).

%%	subscribe(+WSID, +Channel) is det.

subscribe(WSID, Channel) :-
	subscribe(WSID, Channel, _SubChannel).
subscribe(WSID, Channel, SubChannel) :-
	(   subscription(WSID, Channel, SubChannel)
	->  true
	;   assertz(subscription(WSID, Channel, SubChannel))
	).

unsubscribe(WSID, Channel) :-
	unsubscribe(WSID, Channel, _SubChannel).
unsubscribe(WSID, Channel, SubChannel) :-
	retractall(subscription(WSID, Channel, SubChannel)).

%%	sync_gazers(WSID, Files:list(atom)) is det.
%
%	A browser signals it has Files open.   This happens when a SWISH
%	instance is created as well  as   when  a SWISH instance changes
%	state, such as closing a tab, adding   a  tab, bringing a tab to
%	the foreground, etc.

sync_gazers(WSID, Files0) :-
	findall(F, subscription(WSID, gitty, F), Viewing0),
	sort(Files0, Files),
	sort(Viewing0, Viewing),
	(   Files == Viewing
	->  true
	;   ord_subtract(Files, Viewing, New),
	    add_gazing(WSID, New),
	    ord_subtract(Viewing, Files, Left),
	    del_gazing(WSID, Left)
	).

add_gazing(_, []) :- !.
add_gazing(WSID, Files) :-
	inform_me_about_existing_gazers(WSID, Files),
	inform_existing_gazers_about_newby(WSID, Files).

inform_me_about_existing_gazers(WSID, Files) :-
	findall(Gazer, files_gazer(Files, Gazer), Gazers),
	hub_send(WSID, json(_{type:"gazers", gazers:Gazers})).

files_gazer(Files, Gazer) :-
	member(File, Files),
	subscription(WSID, gitty, File),
	visitor_session(WSID, Session),
	session_user(Session, UID),
	public_user_data(UID, Data),
	Gazer = _{file:File, uid:UID}.put(Data).

inform_existing_gazers_about_newby(WSID, Files) :-
	forall(member(File, Files),
	       signal_gazer(WSID, File)).

signal_gazer(WSID, File) :-
	subscribe(WSID, gitty, File),
	broadcast_event(opened(File), File, WSID).

del_gazing(_, []) :- !.
del_gazing(WSID, Files) :-
	forall(member(File, Files),
	       del_gazing1(WSID, File)).

del_gazing1(WSID, File) :-
	unsubscribe(WSID, gitty, File),
	broadcast_event(closed(File), File, WSID).

%%	add_user_details(+Message, -Enriched) is det.
%
%	Add additional information to a message.  Message must
%	contain a `uid` field.

add_user_details(Message, Enriched) :-
	public_user_data(Message.uid, Data),
	Enriched = Message.put(Data).

%%	public_user_data(+UID, -Public:dict) is det.
%
%	True when Public provides the   information  we publically share
%	about UID. This is currently the name and avatar.

public_user_data(UID, Public) :-
	visitor_data(UID, Data),
	(   _{name:Name, avatar:Avatar} :< Data
	->  Public = _{name:Name, avatar:Avatar}
	;   _{avatar:Avatar} :< Data
	->  Public = _{avatar:Avatar}
	;   Public = _{}
	).

%%	get_visitor_data(-Data:dict, +Options) is det.
%
%	Optain data for a new visitor.
%
%	@bug	This may check for avatar validity, which may take
%		long.  Possibly we should do this in a thread.

get_visitor_data(Data, Options) :-
	swish_config:config(user, UserData, Options), !,
	(   _{realname:Name, email:Email} :< UserData
	->  email_avatar(Email, Avatar, Options),
	    Extra = [ name(Name),
		      email(email),
		      avatar(Avatar)
		    ]
	;   _{realname:Name} :< UserData
	->  noble_avatar_url(Avatar, Options),
	    Extra = [ name(Name),
		      avatar(Avatar)
		    ]
	;   _{user:Name} :< UserData
	->  Extra = [ name(Name)
		    ]
	),
	merge_options(Extra, Options, UserOptions),
	dict_create(Data, u, UserOptions).
get_visitor_data(u{avatar:Avatar}, Options) :-
	noble_avatar_url(Avatar, Options).


email_avatar(Email, Avatar, _) :-
	email_gravatar(Email, Avatar),
	valid_gravatar(Avatar), !.
email_avatar(_, Avatar, Options) :-
	noble_avatar(Avatar, Options).


		 /*******************************
		 *	   NOBLE AVATAR		*
		 *******************************/

:- http_handler(swish(avatar), reply_avatar, [prefix]).

%%	reply_avatar(+Request)
%
%	HTTP handler for Noble Avatar images.

reply_avatar(Request) :-
	option(path_info(Local), Request),
	http_reply_file(noble_avatar(Local), [], Request).

noble_avatar_url(HREF, Options) :-
	option(avatar(HREF), Options), !.
noble_avatar_url(HREF, _Options) :-
	noble_avatar(_Gender, Path, true),
	file_base_name(Path, File),
	http_absolute_location(swish(avatar/File), HREF, []).


		 /*******************************
		 *	   BROADCASTING		*
		 *******************************/

%%	chat_broadcast(+Message)
%%	chat_broadcast(+Message, +Channel)
%
%	Send Message to all known SWISH clients. Message is a valid JSON
%	object, i.e., a dict or option list.
%
%	@arg Channel is either an atom or a term Channel/SubChannel,
%	where both Channel and SubChannel are atoms.

chat_broadcast(Message) :-
	debug(chat(broadcast), 'Broadcast: ~p', [Message]),
	hub_broadcast(swish_chat, json(Message)).

chat_broadcast(Message, Channel/SubChannel) :- !,
	must_be(atom, Channel),
	must_be(atom, SubChannel),
	debug(chat(broadcast), 'Broadcast on ~p: ~p',
	      [Channel/SubChannel, Message]),
	hub_broadcast(swish_chat, json(Message),
		      subscribed(Channel, SubChannel)).
chat_broadcast(Message, Channel) :-
	must_be(atom, Channel),
	debug(chat(broadcast), 'Broadcast on ~p: ~p', [Channel, Message]),
	hub_broadcast(swish_chat, json(Message),
		      subscribed(Channel)).

subscribed(Channel, WSID) :-
	subscription(WSID, Channel, _).
subscribed(Channel, SubChannel, WSID) :-
	subscription(WSID, Channel, SubChannel).


		 /*******************************
		 *	     CHAT ROOM		*
		 *******************************/

create_chat_room :-
	current_hub(swish_chat, _), !.
create_chat_room :-
	with_mutex(swish_chat, create_chat_room_sync).

create_chat_room_sync :-
	current_hub(swish_chat, _), !.
create_chat_room_sync :-
	hub_create(swish_chat, Room, _{}),
	thread_create(swish_chat(Room), _, [alias(swish_chat)]).

swish_chat(Room) :-
	(   catch(swish_chat_event(Room), E, chat_exception(E))
	->  true
	;   print_message(warning, goal_failed(swish_chat_event(Room)))
	),
	swish_chat(Room).

chat_exception('$aborted') :- !.
chat_exception(E) :-
	print_message(warning, E).

swish_chat_event(Room) :-
	thread_get_message(Room.queues.event, Message),
	handle_message(Message, Room).

%%	handle_message(+Message, +Room)
%
%	Handle incomming messages

handle_message(Message, _Room) :-
	websocket{opcode:text} :< Message, !,
	atom_json_dict(Message.data, JSON, []),
	debug(chat(received), 'Received from ~p: ~p', [Message.client, JSON]),
	json_message(JSON, Message.client).
handle_message(Message, _Room) :-
	hub{joined:WSID} :< Message, !,
	debug(chat(visitor), 'Joined: ~p', [WSID]).
handle_message(Message, _Room) :-
	hub{left:WSID} :< Message, !,
	(   destroy_visitor(WSID)
	->  debug(chat(visitor), 'Left: ~p', [WSID])
	;   true
	).
handle_message(Message, _Room) :-
	websocket{opcode:close, client:WSID} :< Message, !,
	debug(chat(visitor), 'Left: ~p', [WSID]),
	destroy_visitor(WSID).
handle_message(Message, _Room) :-
	debug(chat(ignored), 'Ignoring chat message ~p', [Message]).


%%	json_message(+Message, +WSID) is det.
%
%	Process a JSON message  translated  to   a  dict.  The following
%	messages are understood:
%
%	  - subscribe channel [subchannel]
%	  - unsubscribe channel [subchannel]
%	  Actively (un)subscribe for specific message channels.
%	  - unload
%	  A SWISH instance is cleanly being unloaded.
%	  - has-open-files files
%	  Executed after initiating the websocket to indicate loaded
%	  files.

json_message(Dict, WSID) :-
	_{ type: "subscribe",
	   channel:ChannelS, sub_channel:SubChannelS} :< Dict, !,
	atom_string(Channel, ChannelS),
	atom_string(SubChannel, SubChannelS),
	subscribe(WSID, Channel, SubChannel).
json_message(Dict, WSID) :-
	_{type: "subscribe", channel:ChannelS} :< Dict, !,
	atom_string(Channel, ChannelS),
	subscribe(WSID, Channel).
json_message(Dict, WSID) :-
	_{ type: "unsubscribe",
	   channel:ChannelS, sub_channel:SubChannelS} :< Dict, !,
	atom_string(Channel, ChannelS),
	atom_string(SubChannel, SubChannelS),
	unsubscribe(WSID, Channel, SubChannel).
json_message(Dict, WSID) :-
	_{type: "unsubscribe", channel:ChannelS} :< Dict, !,
	atom_string(Channel, ChannelS),
	unsubscribe(WSID, Channel).
json_message(Dict, WSID) :-
	_{type: "unload"} :< Dict, !,	% clean close/reload
	sync_gazers(WSID, []).
json_message(Dict, WSID) :-
	_{type: "has-open-files", files:FileDicts} :< Dict, !,
	maplist(dict_file_name, FileDicts, Files),
	sync_gazers(WSID, Files).
json_message(Dict, _WSID) :-
	debug(chat(ignored), 'Ignoring JSON message ~p', [Dict]).

dict_file_name(Dict, File) :-
	atom_string(File, Dict.get(file)).


		 /*******************************
		 *	      EVENTS		*
		 *******************************/

:- unlisten(swish(_, _)),
   listen(swish(Request, Event), swish_event(Event, Request)).

%%	swish_event(+Event, +Request)
%
%	An event happened inside SWISH due to handling Request.

swish_event(Event, _Request) :-
	broadcast_event(Event),
	http_session_id(Session),
	debug(event, 'Event: ~p, session ~q', [Event, Session]),
	event_file(Event, File),
	session_broadcast_event(Event, File, Session, undefined).

%%	broadcast_event(+Event) is semidet.
%
%	If true, broadcast this event.

broadcast_event(updated(_File, _From, _To)).


%%	broadcast_event(+Event, +File, +WSID)
%
%	Event happened that is related to  File in WSID. Broadcast it
%	to subscribed users as a notification.
%
%	@tbd	Extend the structure to allow other browsers to act.

broadcast_event(Event, File, WSID) :-
	visitor_session(WSID, Session),
	session_broadcast_event(Event, File, Session, WSID).

session_broadcast_event(Event, File, Session, WSID) :-
	session_user(Session, UID),
	event_html(Event, HTML),
	Event =.. [EventName|Argv],
	Message0 = _{ type:notify,
		      uid:UID,
		      html:HTML,
		      event:EventName,
		      event_argv:Argv,
		      wsid:WSID
		    },
	add_user_details(Message0, Message),
	chat_broadcast(Message, gitty/File).

%%	event_html(+Event, -HTML:string) mis det.
%
%	Describe an event as an HTML  message   to  be  displayed in the
%	client's notification area.

event_html(Event, HTML) :-
	(   phrase(event_message(Event), Tokens)
	->  true
	;   phrase(html('Unknown-event: ~p'-[Event]), Tokens)
	),
	delete(Tokens, nl(_), SingleLine),
	with_output_to(string(HTML), print_html(SingleLine)).

event_message(created(File)) -->
	html([ 'Created ', \file(File) ]).
event_message(updated(File, _From, _To)) -->
	html([ 'Saved ', \file(File) ]).
event_message(deleted(File, _From, _To)) -->
	html([ 'Deleted ', \file(File) ]).
event_message(closed(File)) -->
	html([ 'Closed ', \file(File) ]).
event_message(opened(File)) -->
	html([ 'Opened ', \file(File) ]).
event_message(download(File)) -->
	html([ 'Opened ', \file(File) ]).
event_message(download(Store, FileOrHash, _Format)) -->
	{ event_file(download(Store, FileOrHash), File)
	},
	html([ 'Opened ', \file(File) ]).

file(File) -->
	html(a(href('/p/'+File), File)).

%%	event_file(+Event, -File) is semidet.
%
%	True when Event is associated with File.

event_file(created(File), File).
event_file(updated(File, _From, _To), File).
event_file(deleted(File, _From, _To), File).
event_file(download(Store, FileOrHash, _Format), File) :-
	(   is_gitty_hash(FileOrHash)
	->  gitty_commit(Store, FileOrHash, Meta),
	    File = Meta.name
	;   File = FileOrHash
	).

		 /*******************************
		 *	       UI		*
		 *******************************/

%%	notifications(+Options)//
%
%	The  chat  element  is  added  to  the  navbar  and  managed  by
%	web/js/chat.js

notifications(_Options) -->
	html(ul([ class([nav, 'navbar-nav', 'pull-right']),
		  id(chat)
		], [])).