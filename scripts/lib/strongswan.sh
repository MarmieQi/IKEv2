#!/bin/bash
# Render connection settings from the normalized network and account model.
generate_swanctl_config() (
    # Restrict the file from creation, including the interval before chmod.
    umask 077
    local output="$1"
    local -n config="$2"
    cat > "$output" <<EOF
connections {
    ikev2-mschapv2 {
        version = 2
        local_addrs = %any
        remote_addrs = %any

        send_cert = always
        send_certreq = no
        encap = yes
        fragmentation = yes
        mobike = yes
        unique = never

        # Windows behind NAT answers the gateway-initiated IKE SA rekey itself but
        # not the deletion of the old IKE SA that follows, so the session still dies
        # after rekeying. Let the Windows client initiate IKE SA rekeying instead.
        rekey_time = 0

        pools = vpn-pool

        # Prefer AES-128/SHA-256 as a conservative software-crypto baseline.
        # GCM is an alternative, not a measured speed winner on CPUs without AES-NI.
        # Keep MODP2048 first for Windows interoperability and every old suite as
        # a fallback for existing clients. GCM uses an explicit PRF, not HMAC integrity.
        proposals = aes128-sha256-modp2048,aes128gcm16-prfsha256-modp2048,aes128-sha256-ecp256,aes128gcm16-prfsha256-ecp256,aes256-sha256-modp2048,aes256-sha256-modp4096,aes256-sha256-modp1024,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024

        local {
            auth = pubkey
            certs = cert.pem
            id = ${config[domain]}
        }

        remote {
            auth = eap-mschapv2
            eap_id = %any
        }

        children {
            net {
                local_ts = ${config[routes]}
                # ESP encrypts actual traffic. Prefer 128-bit AES to reduce AES
                # rounds, with CBC/SHA-256 before GCM until measured on the host.
                # Preserve all legacy fallbacks; negotiate one suite per SA.
                # No DH group here: keep existing Windows CHILD_SA rekey behavior.
                esp_proposals = aes128-sha256,aes128gcm16,aes256-sha256,aes256gcm16,aes256-sha1,aes128-sha1,3des-sha1
                # Windows clients behind NAT may not answer gateway-initiated CHILD_SA rekeying.
                # Let the client initiate CHILD_SA rekeying instead.
                rekey_time = 0
                dpd_action = clear
                start_action = none
            }
        }
    }
}

pools {
    vpn-pool {
        addrs = ${config[pool]}
        dns = ${config[dns]}
    }
}
EOF

    chmod 600 "$output"
    generate_eap_secrets "$3" "$4" >> "$output"
)
