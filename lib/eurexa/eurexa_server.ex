defmodule Eurexa.EurexaServer do
	@moduledoc """
	This is a gen server process, handling one Elixir service for Eureka. Each
	service requires one `EurexaServer`, which sends the regular heartbeats.

	The data sent to the Eureka Server has to comply to this XML schema and can
	be sent either as XML or as JSON data. We will use the JSON format.

	```lang:xml
	<?xml version="1.0" encoding="UTF-8"?>
	<xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema" elementFormDefault="qualified" attributeFormDefault="unqualified">
    <xsd:element name="instance">
        <xsd:complexType>
            <xsd:all>
                <!-- hostName in ec2 should be the public dns name, within ec2 public dns name will
                     always resolve to its private IP -->
                <xsd:element name="hostName" type="xsd:string" />
                <!-- app name
                     Instructions for adding a new app name -
                     <a _jive_internal="true" href="/clearspace/docs/DOC-20965"
                     target="_blank">http://wiki.netflix.com/clearspace/docs/DOC-20965</a> -->
                <xsd:element name="app" type="xsd:string" />
                <xsd:element name="ipAddr" type="xsd:string" />
                <xsd:element name="vipAddress" type="xsd:string" />
                <xsd:element name="secureVipAddress" type="xsd:string" />
                <xsd:element name="status" type="statusType" />
                <xsd:element name="port" type="xsd:positiveInteger" minOccurs="0" />
                <xsd:element name="securePort" type="xsd:positiveInteger" />
                <xsd:element name="homePageUrl" type="xsd:string" />
                <xsd:element name="statusPageUrl" type="xsd:string" />
                <xsd:element name="healthCheckUrl" type="xsd:string" />
               <xsd:element ref="dataCenterInfo" minOccurs="1" maxOccurs="1" />
                <!-- optional -->
                <xsd:element ref="leaseInfo" minOccurs="0"/>
                <!-- optional app specific metadata -->
                <xsd:element name="metadata" type="appMetadataType" minOccurs="0" />
            </xsd:all>
        </xsd:complexType>
    </xsd:element>

    <xsd:element name="dataCenterInfo">
        <xsd:complexType>
             <xsd:all>
                 <xsd:element name="name" type="dcNameType" />
                 <!-- metadata is only required if name is Amazon -->
                 <xsd:element name="metadata" type="amazonMetdataType" minOccurs="0"/>
             </xsd:all>
        </xsd:complexType>
    </xsd:element>

    <xsd:element name="leaseInfo">
        <xsd:complexType>
            <xsd:all>
                <!-- (optional) if you want to change the length of lease - default if 90 secs -->
                <xsd:element name="evictionDurationInSecs" minOccurs="0"
                type="xsd:positiveInteger"/>
            </xsd:all>
        </xsd:complexType>
    </xsd:element>

    <xsd:simpleType name="dcNameType">
        <!-- Restricting the values to a set of value using 'enumeration' -->
        <xsd:restriction base = "xsd:string">
            <xsd:enumeration value = "MyOwn"/>
            <xsd:enumeration value = "Amazon"/>
        </xsd:restriction>
    </xsd:simpleType>

    <xsd:simpleType name="statusType">
        <!-- Restricting the values to a set of value using 'enumeration' -->
        <xsd:restriction base = "xsd:string">
            <xsd:enumeration value = "UP"/>
            <xsd:enumeration value = "DOWN"/>
            <xsd:enumeration value = "STARTING"/>
            <xsd:enumeration value = "OUT_OF_SERVICE"/>
            <xsd:enumeration value = "UNKNOWN"/>
        </xsd:restriction>
    </xsd:simpleType>

    <xsd:complexType name="amazonMetdataType">
        <!-- From <a class="jive-link-external-small"
        href="http://docs.amazonwebservices.com/AWSEC2/latest/DeveloperGuide/index.html?AESDG-chapter-instancedata.html" target="_blank">http://docs.amazonwebservices.com/AWSEC2/latest/DeveloperGuide/index.html?AESDG-chapter-instancedata.html</a> -->
        <xsd:all>
            <xsd:element name="ami-launch-index" type="xsd:string" />
            <xsd:element name="local-hostname" type="xsd:string" />
            <xsd:element name="availability-zone" type="xsd:string" />
            <xsd:element name="instance-id" type="xsd:string" />
            <xsd:element name="public-ipv4" type="xsd:string" />
            <xsd:element name="public-hostname" type="xsd:string" />
            <xsd:element name="ami-manifest-path" type="xsd:string" />
            <xsd:element name="local-ipv4" type="xsd:string" />
            <xsd:element name="hostname" type="xsd:string"/>
            <xsd:element name="ami-id" type="xsd:string" />
            <xsd:element name="instance-type" type="xsd:string" />
        </xsd:all>
    </xsd:complexType>

    <xsd:complexType name="appMetadataType">
        <xsd:sequence>
            <!-- this is optional application specific name, value metadata -->
            <xsd:any minOccurs="0" maxOccurs="unbounded" processContents="skip"/>
        </xsd:sequence>
    </xsd:complexType>

	</xsd:schema>
	```
	"""

	@type status_t :: :UNKNOWN | :UP | :DOWN | :STARTING | :OUT_OF_SERVICE

	defstruct app: "my_app",
	  hostName: "localhost",
	  ipAddr: "127.0.0.1",
	  vipAddress: "",
	  secureVipAddress: "",
	  status: :UNKNOWN,
	  port: 4001,
	  securePort: 0,
	  homePageUrl: nil,
	  statusPageUrl: nil,
	  healthCheckUrl: nil,
	  dataCenterInfo: %{
	  	name: "MyOwn",
	  	metadata: %{}
	  },
	  leaseInfo: %{evictionDurationInSecs: 30},
	  metadata: %{}

  use GenServer
  require Logger

	@doc """
	Starts the Eurexa Server process for application `app_name`.
	"""
	def start_link(app_name) do
		GenServer.start_link(__MODULE__, [app_name], name: __MODULE__)
	end

	def init([app_name]) do
    conf = Application.get_env(:eurexa, app_name)

		app = %__MODULE__{app: app_name, status: :UP,
      hostName: conf[:app][:hostname],
      port: conf[:app][:port]
    }

    server  = conf[:eureka_server]
    port    = conf[:eureka_port]
    prefix  = conf[:eureka_prefix]
    version = conf[:eureka_version]

    mod = case version do
      1 -> Eurexa.EurekaV1
      2 -> Eurexa.EurekaV2
    end

    eureka_base_url = "http://#{server}:#{port}#{prefix}"
		timer = trigger_heartbeat(eureka_base_url, app, mod)
		{:ok, resp} = mod.register(eureka_base_url, app)
    Logger.info "Registration suceeded with response #{inspect resp}"
		{:ok, {app, timer, eureka_base_url, mod}}
	end

	def terminate(reason, {app, timer, eureka_base_url, mod}) do
    Logger.info "Terminating: derigster #{app} as Eureka"
		:timer.cancel(timer)
		mod.deregister(eureka_base_url, app.app, app.hostName)
	end

	@doc """
	Initializes the interval timer sending heartbeats to Eureka
	after 3/4 of the eviction interval, which usually 30 seconds.
	So, we are sending heatbeats every 22,5 seconds.
	"""
	def trigger_heartbeat(eureka_base_url,
                        %__MODULE__{app: app_name, hostName: hostname,
			                  leaseInfo: %{evictionDurationInSecs: interval}},
                        mod) do
		{:ok, tref} = :timer.apply_interval(interval * 750, mod, :send_heartbeat, [eureka_base_url, app_name, hostname])
		tref
	end

  def make_instance_data(app = %__MODULE__{}) do
    {:ok, json} = Poison.encode(app)
    json
  end
end
