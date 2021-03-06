cisconexus5k_portchannel {
  "200":
    ensure                => "absent",
    untagged_vlan         => "20",
    tagged_vlan           => "17,19",
    mtu                   => "9212",
    speed                 => "10000",
    istrunkforportchannel => "true",
    vpc                   => "200"

}

cisconexus5k_interface {
  "Eth1/5":
    ensure                      => "present",
    switchport_mode             => "access",
    istrunkforinterface         => "false",
    deletenativevlaninformation => "true",
    removeallassociatedvlans    => "true",
    shutdown                    => 'false',
    access_vlan                 => '20',
    mtu                         => '9216',
    speed                       => '10000'

}

cisconexus5k_interface {
  "Eth1/6":
    ensure                      => "present",
    switchport_mode             => "access",
    istrunkforinterface         => "false",
    deletenativevlaninformation => "true",
    removeallassociatedvlans    => "true",
    shutdown                    => 'false',
    access_vlan                 => '20',
    mtu                         => '9216',
    speed                       => '10000'

}

cisconexus5k_vlan {
  '99':
    ensure => "present"
}

cisconexus5k_vlan {
  '17':
    ensure => "present"
}

cisconexus5k_vlan {
  '20':
    ensure => "present"
}
