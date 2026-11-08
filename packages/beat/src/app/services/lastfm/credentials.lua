-- The application's Last.fm API account. These identify beat, not a listener: each person who
-- connects authorizes their own account, and auth.getSession returns a session key for that
-- account. The shared secret signs the app's calls and is necessarily carried by the desktop
-- client. Keep it out of logs and error messages.
return { apiKey = "e20678c043c2e8c9983113e921bc731b", apiSecret = "ae69d210df930eed322f45d826dd336e" }
