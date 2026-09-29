# Access

The Access pane holds the connection to Home Assistant and the three decryption keys. This page covers connecting to an MQTT broker over TLS.


## MQTT over TLS

Click the lock beside the port under **Broker** to turn TLS on; the port changes to 8883. FindMySync+ then checks the broker's certificate the way Safari checks a website's: it has to be current, trusted by this Mac, and issued to the name in the host field. When a check fails, the Status log shows one error with the reason and the scheduler stops.

### Connect by the name on the certificate

A certificate names the host it belongs to, such as `yourname.duckdns.org`. Enter that name in the host field, in place of `homeassistant.local` or an IP address.

Inside your own network that name may point at your public address, or a DNS filter may block it. In either case, add a line to `/etc/hosts` on this Mac that points the name at the broker's local address:

```
192.168.1.10  yourname.duckdns.org
```

Open the file with `sudo nano /etc/hosts` in Terminal. A local DNS record on your router or DNS server does the same for every device on the network.

### A self-signed certificate

If you made the broker's certificate yourself, this Mac has to trust it first. Open the certificate, or the certificate authority that signed it, in Keychain Access, expand **Trust**, and set **When using this certificate** to **Always Trust**.

macOS accepts such a certificate only when it:

- has the host name in its Subject Alternative Name, not only in its Common Name
- is valid for 825 days or fewer
- lists server authentication as an Extended Key Usage
- uses an RSA key of 2048 bits or more and a SHA-2 signature

This command makes one that meets all four, for the host `yourname.duckdns.org`:

```
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout broker.key -out broker.pem \
  -subj "/CN=yourname.duckdns.org" \
  -addext "subjectAltName=DNS:yourname.duckdns.org" \
  -addext "extendedKeyUsage=serverAuth"
```

For the Mosquitto add-on, copy `broker.pem` and `broker.key` into Home Assistant's `/ssl` folder, set the add-on's `certfile` and `keyfile` to them, and restart the add-on.

### When a certificate is refused

The error names one of three reasons:

- **It has expired or is not yet valid.** A Let's Encrypt certificate lasts 90 days; check that the add-on that renews it is still running, then restart the Mosquitto add-on so it loads the new one.
- **It is issued to a different name than the host you entered.** Enter the certificate's name in the host field, with the `/etc/hosts` line above if needed.
- **This Mac does not trust it.** For a self-signed certificate, trust it in Keychain Access as above.

After fixing it, press **Verify** in **Connection Test**, then turn the **Scheduler** back on in Home.
