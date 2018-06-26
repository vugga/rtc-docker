# RTC-Docker

Out-of-the-box docker image for WebRTC dev/test purpose. i forked and combined old WebRTC implementations to fit a single command for deployment, nicely packed in a Dockerfile, share it, contribute, rewrite it your way.

This project contains necessary servers to build a full WebRTC web app. mainly

+ Collide - go websocket server for signaling peers.
+ ICE Server with TURN/STUN servers for UDP media transmission.
+ Web server for joining rooms.
+ Static web app, the one you see on the fronend.

## Deploy
You can deploy this docker image anywhere.

Note: WebRTC can only be run on secure connections (HTTPS).

## Running
Once you've build the image, replace `image/tag` with your actual image that you've just built

``` bash
docker run --rm \
  -p 8080:8080 -p 8089:8089 -p 3478:3478 -p 3478:3478/udp -p 3033:3033 \
  -p 59000-65000:59000-65000/udp \
  -e PUBLIC_IP=<server public IP> \
  -v <path to constants.py parent folder>:/apprtc_configs \
  -t -i image/tag
```

About ports:

+ `8080` is used for room server;
+ `8089` is used for signal server;
+ `3033` is used for ICE server;
+ `3478` and `59000-65000` is used for TURN/STUN server;

So make sure your firewall has opened those ports.

Note that range ports could be very slow and memory hungry, we can either replace all `-p` options into a single `--net=host` option, or disable userland proxy, see detail info in [this issue](https://github.com/moby/moby/issues/11185).

About how to modify `constants.py`, see [this example from original project](https://github.com/Piasy/WebRTC-Docker/blob/master/apprtc-server/constants.py), `ICE_SERVER_BASE_URL`, `ICE_SERVER_URL_TEMPLATE` and `WSS_INSTANCES` has been modified.


###Authors
[Patrick Muhire](https://github.com/1k2k)