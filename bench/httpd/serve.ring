# The server natives (src/httpd.zig), driven by bench/httpd.py: a program that holds
# its own request loop and answers each request with the parts the natives read.
#
#     rnxc exec serve.ring        RPP_HTTPD_PORT=<port>
#
# /stop ends the loop; /idle answers how many times rpp_http_next(50) came back -1
# since the last /idle; /noreply is left unanswered; /status?<n> answers with status
# n; anything else is echoed: method, path, query, two headers, the body's length
# and the body, separated by "|".

? "reply with nothing pending: " + rpp_http_reply(200, "text/plain", "x")
? "method with nothing pending: [" + rpp_http_method() + "]"
nPort = number(sysget("RPP_HTTPD_PORT"))
if rpp_http_listen(nPort) = 1
	? "listening"
else
	? "listen failed on " + nPort
	shutdown(2)
ok

nIdle = 0
while true
	nGot = rpp_http_next(50)
	if nGot = -1
		nIdle++
		loop
	ok
	if nGot = 0
		? "the listener is gone"
		exit
	ok
	cPath = rpp_http_path()
	if cPath = "/stop"
		rpp_http_reply(200, "text/plain", "stopping")
		exit
	but cPath = "/idle"
		rpp_http_reply(200, "text/plain", "" + nIdle)
		nIdle = 0
	but cPath = "/noreply"
		# left unanswered: the next rpp_http_next answers it for the program
	but cPath = "/status"
		rpp_http_reply(number(rpp_http_query()), "text/x-probe", "status " + rpp_http_query())
	else
		cBody = rpp_http_body()
		rpp_http_reply(200, "application/x-echo", rpp_http_method() + "|" + cPath + "|" + rpp_http_query() + "|" +
			rpp_http_header("X-Probe") + "|" + rpp_http_header("X-Missing") + "|" + len(cBody) + "|" + cBody)
	ok
end
? "done"
