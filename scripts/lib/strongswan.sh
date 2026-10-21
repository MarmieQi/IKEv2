#!/bin/bash
# Render connection settings from the normalized network and account model.
generate_swanctl_config() {
    cat > /etc/swanctl/swanctl.conf <<EOF
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

        # Windows requires MODP2048 in the first proposal when the gateway initiates IKE rekeying.
        proposals = aes256-sha256-modp2048,aes256-sha256-modp4096,aes128-sha256-modp2048,aes256-sha256-modp1024,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024

        local {
            auth = pubkey
            certs = cert.pem
            id = $VPN_DOMAIN
        }

        remote {
            auth = eap-mschapv2
            eap_id = %any
        }

        children {
            net {
                local_ts = $VPN_LOCAL_TS
                esp_proposals = aes256-sha256,aes128-sha256,aes256-sha1,aes128-sha1,3des-sha1
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
        addrs = $VPN_POOL
        dns = $VPN_DNS
    }
}
EOF

    chmod 600 /etc/swanctl/swanctl.conf
    generate_eap_secrets >> /etc/swanctl/swanctl.conf
}
