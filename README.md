# WebRTC-Docker

Out-of-the-box docker images for AppRTC dev/test purpose.

## AppRTC-Server

``` bash
docker run --rm \
  -p 8080:8080 -p 8089:8089 -p 3478:3478 -p 3478:3478/udp -p 3033:3033 \
  -p 59000-65000:59000-65000/udp \
  -e PUBLIC_IP=<server public IP> \
  -v <path to constants.py parent folder>:/apprtc_configs \
  -t -i piasy/apprtc-server
```

About port publish:

+ `8080` is used for room server;
+ `8089` is used for signal server;
+ `3033` is used for ICE server;
+ `3478` and `59000-65000` is used for TURN/STUN server;

So make sure your firewall has opened those ports.

Note that publish range ports could be very slow and memory consuming, we can either replace all `-p` options into a single `--net=host` option, or disable userland proxy, see detail info in [this issue](https://github.com/moby/moby/issues/11185).

About how to modify `constants.py`, see [this example](https://github.com/Piasy/WebRTC-Docker/blob/master/apprtc-server/constants.py), `ICE_SERVER_BASE_URL`, `ICE_SERVER_URL_TEMPLATE` and `WSS_INSTANCES` has been modified.