require 'pp'
require 'puppet'
require 'puppet/util'
require 'puppet/util/network_device/base'
require 'puppet/util/network_device/cisconexus5k/facts'

#
# Main device class for Cisco nexus5k module
# This class is called by the provider and contains methods
# for performing all operations
# * parse_vlans: get a list of VLANs on the device
#   as a hash of hash, used by the lookup function of the 
#   provider
# * update_vlan: delete/create VLAN
#

class Puppet::Util::NetworkDevice::Cisconexus5k::Device < Puppet::Util::NetworkDevice::Base

  include Puppet::Util::NetworkDevice::IPCalc

  attr_accessor :enable_password

  def initialize(url, options = {})
    super(url, options)
    @enable_password = options[:enable_password] || parse_enable(@url.query)
    transport.default_prompt = /[#>]\s?\z/n
  end

  def parse_enable(query)
    if query
      params = CGI.parse(query)
      params['enable'].first unless params['enable'].empty?
    end
  end

  def connect
    transport.connect
    login
    transport.command("terminal length 0") do |out|
      enable if out =~ />\s?\z/n
    end
    #find_capabilities
  end

  def disconnect
    transport.close
  end

  def command(cmd = nil)
    connect
    out = execute(cmd) if cmd
    yield self if block_given?
    disconnect
    out
  end

  def execute(cmd)
    transport.command(cmd)
  end

  def login
    return if transport.handles_login?
    if @url.user != ''
      transport.command(@url.user, :prompt => /^Password:/)
    else
      transport.expect(/^Password:/)
    end
    transport.command(@url.password)
  end

  def enable
    raise "Can't issue \"enable\" to enter privileged, no enable password set" unless enable_password
    transport.command("enable", :prompt => /^Password:/)
    transport.command(enable_password)
  end

  IF = {
    :FastEthernet => %w{FastEthernet FastEth Fast FE Fa F},
    :GigabitEthernet => %w{GigabitEthernet GigEthernet GigEth GE Gi G},
    :TenGigabitEthernet => %w{TenGigabitEthernet TE Te},
    :Ethernet => %w{Ethernet Eth E},
    :Serial => %w{Serial Se S},
    :PortChannel => %w{PortChannel Port-Channel Po},
    :POS => %w{POS P},
    :VLAN => %w{VLAN VL V},
    :Loopback => %w{Loopback Loop Lo},
    :ATM => %w{ATM AT A},
    :Dialer => %w{Dialer Dial Di D},
    :VirtualAccess => %w{Virtual-Access Virtual-A Virtual Virt}
  }

  def canonalize_ifname(interface)
    IF.each do |k,ifnames|
      if found = ifnames.find { |ifname| interface =~ /^#{ifname}\s*\d/i }
        found = /^#{found}(.+)\Z/i.match(interface)
        return "#{k.to_s}#{found[1]}".gsub(/\s+/,'')
      end
    end
    interface
  end

  def facts
    @facts ||= Puppet::Util::NetworkDevice::Cisconexus5k::Facts.new(transport)
    facts = {}
    command do |ng|
      facts = @facts.retrieve
    end
    facts
  end

  def parse_vlans
    vlans = {}
    out = execute("show vlan brief")
    lines = out.split("\n")
    lines.shift; lines.shift; lines.shift; lines.pop
    vlan = nil
    lines.each do |line|
     case line
            # vlan    name    status
      when /^(\d+)\s+(\w+)\s+(\w+)\s+([a-zA-Z0-9,\/. ]+)\s*$/
        vlan = { :name => $1, :vlanname => $2, :status => $3, :interfaces => [] }
        if $4.strip.length > 0
          vlan[:interfaces] = $4.strip.split(/\s*,\s*/)
        end
        vlans[vlan[:name]] = vlan
      when /^\s+([a-zA-Z0-9,\/. ]+)\s*$/
        raise "Invalid show vlan summary output" unless vlan
        if $1.strip.length > 0
          vlan[:interfaces] += $1.strip.split(/\s*,\s*/)
        end
      else
        next 
      end
    end
    vlans
  end
  
  def parse_zones
    zones = {}
    out = execute("show zone")
    lines = out.split("\n")
    lines.shift; lines.pop
    zone = nil
    lines.each do |l|
      if l =~ /^zone name\s*(\S*)\s*vsan\s*(\d*)/
        zone = { :name => $1, :vsanid => $2, :membertype => [], :member => [] }
      end
      if l =~ /pwwn\s*(\S*)/
        zone[:member] += $1.map{ |ifn| canonalize_ifname(ifn) }
        zone[:membertype] += 'pwwn'.map{ |ifn| canonalize_ifname(ifn) }
      end
      if l =~/fcalias name\s*(\S*)\s*vsan\s*(\d*)/
        zone[:member] += $1.map{ |ifn| canonalize_ifname(ifn) }
        zone[:membertype] += 'fcalias'.map{ |ifn| canonalize_ifname(ifn) }
      end
      zones[zone[:name]] = zone
    end 
    zones 
  end
 
  def parse_alias
    malias ={}
    out=execute("show device-alias database") 
    Puppet.debug "show device-alias database \n  #{out} "
    lines = out.split("\n")
    lines.shift ; lines.pop
    lines.each do |l|
      if l =~ /device-alias\s*name\s*(\S*)\s*(\S*)\s*(\S*)/
        m_alias = { :name => $1, :member => $3 }        
        malias[m_alias[:name]] = m_alias
      end
    end
    malias
  end 

  def update_alias(id, is = {}, should = {})  
    member=should[:member]
    if should[:ensure] == :absent
      Puppet.debug "Removing #{id} from device alias"
      execute("conf t")
      execute("device-alias database")
      execute("no device-alias name #{id} ")   
      execute("device-alias commit")
      execute("exit")
      execute("exit")
      return
    end

    Puppet.debug "Creating Alias id #{id} member #{member} "
    execute("conf t")
    execute("device-alias database")
    Puppet.debug "id #{id} member #{member}  "
    out = execute("device-alias name  #{id} pwwn #{member}")
    if ( out =~ /% Invalid/ )
      raise "The command input #{memberval} is invalid"
    end 
    if (out =~ /already present/)
      raise "Another device-alias already present with the same pwwn"
    end
    execute("device-alias commit") 
    execute("exit")
    execute("exit")
  end 
 
  def update_vlan(id, is = {}, should = {})
    if should[:ensure] == :absent
      Puppet.info "A VLAN #{id} is being removed from the device."
      execute("conf t")
      out = execute("no vlan #{id}")
      if out =~ /Invalid/
        raise "The VLAN id value/range is invalid."
      end
      execute("exit")
      return
    end

    # We're creating or updating an entry
    execute("conf t")
    out = execute("vlan #{id}")
    if out =~ /Invalid/
        raise "The VLAN id value/range is invalid."
    end
    [is.keys, should.keys].flatten.uniq.each do |property|
      Puppet.debug("trying property: #{property}: #{should[property]}")
      next if property != :vlanname
      execute("name #{should[property]}")
      Puppet.info "Successfully created a VLAN #{id}."
    end
    out = execute("exit")
    if out =~/ERROR:\s*(.*)/
        Puppet.info "#{$1}"
    end
    
    execute("exit")
  end
  
  def update_interface(id, is = {}, should = {},interfaceid = {},nativevlanid={},istrunk = {},encapsulationtype={},isnative={},deletenativevlaninformation={},unconfiguretrunkmode={},
shutdownswitchinterface={},interfaceoperation={})
    responseinterface = execute("show interface #{interfaceid}")
    if ( responseinterface =~ /Invalid/ )
      raise "The interface #{interfaceid} does not exist on the switch."
    end
    if should[:ensure] == :absent || interfaceoperation == "remove"
      Puppet.info "The interface #{interfaceid} is being removed from the VLAN #{id}."
      execute("conf t")
      execute("interface #{interfaceid}")
      if istrunk == "true"
        responsetrunk = execute("show interface #{interfaceid} trunk")
        if ( responsetrunk =~ /Invalid/ )
          Puppet.info("The trunking is not configured on the interface #{interfaceid}.")
          return
        end
        interfacestatus = gettrunkinterfacestatus(responsetrunk)
        if ( interfacestatus != "trunking" )
          Puppet.info "The interface #{interfaceid} is in access mode."
          return
        end
        Puppet.info "The interface #{interfaceid} is in trunk mode."
        if deletenativevlaninformation == "true"
         Puppet.info "The native VLAN information is being deleted."
          execute("no switchport trunk native vlan #{nativevlanid}")
        end
        execute("switchport trunk allowed vlan remove #{id}")
        if unconfiguretrunkmode == "true"
          Puppet.info "The trunk mode is being unconfigured."
          execute("no switchport mode trunk")
        end
        if shutdownswitchinterface == "true" && unconfiguretrunkmode == "false"
          Puppet.info "The interface #{interfaceid} is being shut down."
          execute("shutdown")
        end
      else
          Puppet.info "The interface #{interfaceid} is in access mode."
          execute("no switchport access vlan #{id}")
          execute("no switchport mode access")
          execute("shutdown")
      end
      execute("exit")
      execute("exit")
      return
    end

    # We're creating or updating an entry
    execute("conf t")
    interfaceid = should[:interface]
    encapsulationtype = should[:interfaceencapsulationtype]
    nativevlanid = should[:nativevlanid]
    execute("interface #{interfaceid}")
    [is.keys, should.keys].flatten.uniq.each do |property|
      Puppet.debug("trying property: #{property}: #{should[property]}")
      next if property != :istrunkforinterface
        if should[:istrunkforinterface] == "true"
          Puppet.debug("Verify whether or not the specified interface is already configured as a trunk interface.")
          responsetrunk = execute("show interface #{interfaceid} trunk")
          if ( responsetrunk =~ /Invalid/ )
            Puppet.info("The trunking feature is not already configured for  the interface #{interfaceid}. Configure trunking feature on this interface.")
            return
          end
          Puppet.info("The trunk interface status for #{interfaceid} is being retrieved.")
          interfacestatus = gettrunkinterfacestatus(responsetrunk)
          Puppet.info("The encapsulationtype for the interface #{interfaceid} is being retrieved.")
          updateencapsulationtype = getencapsulationtype(interfaceid,encapsulationtype)
          if ( interfacestatus != "trunking" )
            execute("switchport")
            if ( updateencapsulationtype != "" )
              execute("switchport trunk encapsulation #{updateencapsulationtype}")
            end
            execute("switchport mode trunk")
          end
          removeallassociatedvlans = should[:removeallassociatedvlans]
          if removeallassociatedvlans == "true"
            Puppet.info("The associated VLANs are being deleted.")
            execute("switchport trunk allowed vlan none")
          end
          isnative = should[:isnative]
          if isnative == "true"
            Puppet.info("A switch interface with a native VLAN is being configured.")
            execute("switchport trunk native vlan #{nativevlanid}")
          end
          execute("switchport trunk allowed vlan add #{id}")
          execute("no shutdown")
        else
          Puppet.info "The interface #{interfaceid} is being configured into access mode."
          execute("switchport")
          execute("switchport mode access")
          execute("switchport access vlan #{id}")
          execute("no shutdown")
        end
    end
    execute("exit")
    execute("exit")
    return
  end

  def getencapsulationtype(interfaceid,encapsulationtype)
    updateencapsulationtype = ""
    encapsulationtypelist = ""
    if encapsulationtype != ""
      responsecapability = execute("show interface #{interfaceid} Capabilities")
      if responsecapability =~ /Trunk encap. type:\s+(\S+)/
        encapsulationtypelist = $1
      end
      if ( encapsulationtypelist =~ /,/ )
        Puppet.info("The multiple encapsulation types exist.")
        updateencapsulationtype = encapsulationtype
      else
        updateencapsulationtype = encapsulationtype
        if encapsulationtype == "dot1q"
          updateencapsulationtype = "802.1Q"
        end
        if updateencapsulationtype == encapsulationtypelist
          updateencapsulationtype = ""
        else
          updateencapsulationtype = encapsulationtype
        end
      end
    end
    return updateencapsulationtype
  end

  def gettrunkinterfacestatus(response)
    response = response.gsub("\n",'')
    if response =~ /--.+\s+\s+(tr\S+)\s+/
      trunk = $1
    end
    if ( trunk =~ /trnk-bndl/ )
      trunk = "trunking"
    end
    return trunk
  end

  def update_portchannel(id, is = {}, should = {}, portchannel = {}, istrunkforportchannel = {},portchanneloperation = {})
    if portchannel !~ /\d/
      Puppet.info("The port channel #{portchannel} should be numeric value.")
      return
    end
    pchannel = "po#{portchannel}"
    responsepchannel = execute("show interface #{pchannel}")
    if ( responsepchannel =~ /Invalid/ )
      raise "A port channel #{portchannel} does not exist on the switch."
      return
    end
    if should[:ensure] == :absent || portchanneloperation == "remove"
      Puppet.info "A port channel #{portchannel} is being deleted from the device VLAN #{id}."
      execute("conf t")
      execute("interface port-channel #{portchannel}")
      if (istrunkforportchannel == "true")
        execute("switchport trunk allowed vlan remove #{id}")
      end
      execute("no switchport access vlan #{id}")
      execute("exit")
      return
    end

    # We're creating or updating an entry
    execute("conf t")
    portchannel = should[:portchannel]
    istrunkforportchannel = should[:istrunkforportchannel]
    execute("interface port-channel #{portchannel}")
    execute("switchport")
    if (istrunkforportchannel == "true")
      Puppet.info "A port channel #{portchannel} is being configured into trunk mode."
      portchannelencapsulationtype = should[:portchannelencapsulationtype]
      addmembertotrunkvlan(id,portchannel,portchannelencapsulationtype)
    else
      Puppet.info "A port channel #{portchannel} is being configured into access mode."
      execute("switchport mode access")
      execute("switcport access vlan #{id}")
    end
    execute("no shutdown")
    execute("exit")
    execute("exit")
    return
  end

  def addmembertotrunkvlan(vlanid,portchannelid,portchannelencapsulationtype)
    portchannel = "po#{portchannelid}"
    Puppet.info("The encapsulationtype for portchannel #{portchannelid} is being retrieved.")
    updateencapsulationtype = getencapsulationtype(portchannel,portchannelencapsulationtype)
    responseportchannel = execute("show interface #{portchannel} trunk")
    if ( responseportchannel =~ /Invalid/ )
      Puppet.info("The trunking feature is not already configured for  the port channel #{interfaceid}. Configure trunking feature on this interface.")
      return
    end
    Puppet.info("The trunk port channel status for portchannel #{portchannel} is being retrieved.")
    interfacestatus = gettrunkinterfacestatus(responseportchannel)
    if ( interfacestatus != "trunking" )
      execute("switchport")
      if ( updateencapsulationtype != "" )
        execute("switchport trunk encapsulation #{updateencapsulationtype}")
      end
    execute("switchport mode trunk")
    end
    notaddedtoanyvlan = "false"
    out = execute("show interface #{portchannel} switchport")
    if out =~ /Trunking VLANs Allowed:\s(\S+)\s/
      trunkportvlanid = $1
    end
    if (trunkportvlanid.length == 0 || trunkportvlanid == "NONE")
      notaddedtoanyvlan = "true"
    end
    if notaddedtoanyvlan == "true"
      execute("switchport trunk allowed vlan #{vlanid}")
    else
      execute("switchport trunk allowed vlan add #{vlanid}")
    end
    return
  end

  def update_zone(id, is = {}, should = {}, vsanid = {}, membertype = {}, member = {})
    mem = member.split(",")
    if should[:ensure] == :absent
      Puppet.info "Zone #{id} is being destroyed."
      execute("conf t")
      Puppet.debug "conf t"
      out = execute("zone name #{id} vsan #{vsanid}")
      Puppet.debug "zone name #{id} vsan #{vsanid}"
      if ( out =~/Illegal/ )
        raise "The zone name #{id} is not valid on the switch" 
      end
      if ( out =~ /% Invalid/ )
        raise "The VSAN Id #{vsanid} is not valid on the switch"
      end
      if ( out =~ /not configured/ )
        raise "The VSAN Id #{vsanid} is not valid on the switch"
      end
      mem.each do |memberval|
       out = execute("no member #{membertype} #{memberval}")
       Puppet.debug "no member #{membertype} #{memberval}"
       #if ( out =~ /% Invalid/ )
       #  raise "invalid command input #{memberval}"
       #end
      end
      #check whether its was a last member of not
      out = execute("show zone name #{id} vsan #{vsanid}")
      Puppet.debug "show zone name #{id} vsan #{vsanid}"
      lines = out.split("\n")
      lines.shift; lines.pop
      outputlength = lines.length
      if ( outputlength == 1 )
        #No last member need to remove the zone"
        execute("no zone name #{id} vsan #{vsanid}")
        Puppet.debug "no zone name #{id} vsan #{vsanid}"
      end
      execute("exit")
      execute("exit")
      return
    end
	Puppet.info "Zone #{id} is being created."
    # We're creating or updating an entry
    execute("conf t")
    Puppet.debug "conf t"
    out = execute("zone name #{id} vsan #{vsanid}")
    Puppet.debug "zone name #{id} vsan #{vsanid}"
    if ( out =~/Illegal/ )
      raise "The zone name #{id} is not valid on the switch" 
    end
    if ( out =~ /% Invalid/ )
      raise "The VSAN Id #{vsanid} is not valid on the switch"
    end
    if ( out =~ /not configured/ )
      raise "The VSAN Id #{vsanid} is not valid on the switch"  
    end
    mem.each do |memberval|
      out =  execute("member #{membertype} #{memberval}")
      Puppet.debug "member #{membertype} #{memberval}"
      if ( out =~ /% Invalid/ )
        raise "The command input #{memberval} is invalid"
      end
    end
    execute("exit")
    execute("exit")
  end
end
