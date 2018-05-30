#!/bin/bash

# Export environment variables for openstack access
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=SFC
export OS_USERNAME=sfc_user
export OS_PASSWORD=sfc_user@123
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2

SOURCE_NET="192.162.10.0/24"
SFC_NET="194.164.10.0/24"
KEY_PAIR_NAME="sfc"

####Create network required for SFC
openstack network create sfc_network
openstack subnet create --subnet-range $SFC_NET --network sfc_network  sfc_network-v4

openstack network create source_network
openstack subnet create --subnet-range $SOURCE_NET --network source_network  source_network-v4

#Create Router
openstack router create sfc_router
openstack router add subnet sfc_router sfc_network-v4
neutron router-gateway-set sfc_router provider1

openstack router create source_router
openstack router add subnet source_router source_network-v4
neutron router-gateway-set source_router provider1

#Create required ports
openstack port create --network source_network --allowed-address ip-address=$SFC_NET  --allowed-address ip-address=$SOURCE_NET source_port
openstack port create --network source_network  --allowed-address ip-address=$SFC_NET  --allowed-address ip-address=$SOURCE_NET  vm1p1
openstack port create --network sfc_network --allowed-address ip-address=$SFC_NET  --allowed-address ip-address=$SOURCE_NET  vm1p2
openstack port create --network sfc_network --allowed-address ip-address=$SFC_NET  --allowed-address ip-address=$SOURCE_NET  vm2p1
openstack port create --network sfc_network --allowed-address ip-address=$SFC_NET  --allowed-address ip-address=$SOURCE_NET  vm2p2
openstack port create --network sfc_network --allowed-address ip-address=$SFC_NET --allowed-address ip-address=$SOURCE_NET  proxy_port
openstack port create --network sfc_network --allowed-address ip-address=$SFC_NET --allowed-address ip-address=$SOURCE_NET  dest_port

#Create Instances
openstack server create --image Iperf --flavor m1.sfc --key-name $KEY_PAIR_NAME --port source_port sourceVM
sleep 30
openstack server create --image Pfsense --flavor m1.medium --key-name $KEY_PAIR_NAME --port vm1p1 --port vm1p2 pfsense
#openstack server create --image Iperf --flavor m1.medium --key-name sfc --port vm1p1 --port vm1p2 pfsense
sleep 30
openstack server create --image Snort --flavor m1.medium --key-name $KEY_PAIR_NAME --port vm2p1 --port vm2p2  NIDS
#openstack server create --image Iperf --flavor m1.medium --key-name sfc --port vm2p1 --port vm2p2  NIDS
sleep 30
openstack server create --image Haproxy --flavor m1.medium --key-name $KEY_PAIR_NAME --port  proxy_port LoadBalancer
#openstack server create --image Iperf --flavor m1.medium --key-name sfc --port  proxy_port LoadBalancer
sleep 30
openstack server create --image Iperf --flavor m1.sfc --key-name $KEY_PAIR_NAME --port dest_port destVM
sleep 30

#Assign Floating IP to VNF
sourceVMfloatingIP="$(openstack floating ip create provider1 | grep floating_ip_address | cut -d'|' -f3)"
openstack server add floating ip sourceVM $sourceVMfloatingIP
NIDSfloatingIP="$(openstack floating ip create provider1 | grep floating_ip_address | cut -d'|' -f3| tr -d ' ')"
openstack server add floating ip NIDS $NIDSfloatingIP
LBfloatingIP="$(openstack floating ip create provider1 | grep floating_ip_address | cut -d'|' -f3)"
openstack server add floating ip LoadBalancer $LBfloatingIP
destfloatingIP="$(openstack floating ip create provider1 | grep floating_ip_address | cut -d'|' -f3| tr -d ' ')"
openstack server add floating ip destVM $destfloatingIP

#Create Port Pair for SFC
#openstack sfc  port pair create  --description "Firewall SF instance 1"  --ingress vm1p1 --egress vm1p2 PP1
openstack sfc port pair create --description "Snort SFC instance vm2" --ingress vm2p1 --egress vm2p2 PP2


#Create Port Pair Group:
#openstack sfc port pair group create --port-pair PP1 PG1
openstack sfc port pair group create --port-pair PP2 PG2


#Get Source VM IP and Destination VM Ip
sourceIP="$(openstack port list | grep source_port | cut -d'_' -f 3 |  cut -d',' -f 1| cut -d'=' -f 2 | tr -d "'")"
proxyIP="$(openstack port list | grep proxy_port | cut -d'_' -f 3 |  cut -d',' -f 1| cut -d'=' -f 2 | tr -d "'")"
nextHop="$(openstack port list | grep vm1p1 | cut -d'_' -f 2 | cut -d'=' -f 2| cut -d',' -f 1| tr -d "'")"
revnextHop="$(openstack port list | grep vm1p2 | cut -d'_' -f 2 | cut -d'=' -f 2| cut -d',' -f 1| tr -d "'")"

echo "souroe Ip is ======> $sourceIP"
echo "proxy Ip is ======>$proxyIP"
echo "nexthop Ip is ======>$nextHop"
echo "reverse nexthop Ip is ======>$revnextHop"
#Create Flow Classifier:
flowClassifier="openstack sfc flow classifier create "
flowClassifier+=" --ethertype IPv4 --source-ip-prefix "
flowClassifier+=$sourceIP
flowClassifier+="/32 --destination-ip-prefix "
flowClassifier+=$proxyIP
flowClassifier+="/32 --logical-source-port vm1p2 FC1 "
echo "flowclassifier is =================>$flowClassifier \n\n\n\n\n\n"
sleep 10
$flowClassifier

#Create Chain:
openstack sfc port chain create --port-pair-group PG2 --flow-classifier FC1 PC1


######################Create reverse Port Chain

#openstack sfc  port pair create  --description "Firewall SF instance 1"  --ingress vm1p2 --egress vm1p1 PP1_REV_1
openstack sfc port pair create --description "Snort SFC instance vm2" --ingress vm2p2 --egress vm2p1 PP2_REV_1


#Create Port Pair Group:
#openstack sfc port pair group create --port-pair PP1_REV_1 PG1_REV_1
openstack sfc port pair group create --port-pair PP2_REV_1 PG2_REV_1

#Create Flow Classifier:
#create Reverse flow classifier
revflowClassifier="openstack sfc flow classifier create "
revflowClassifier+=" --ethertype IPv4 --source-ip-prefix "
revflowClassifier+=$proxyIP
revflowClassifier+="/32 --destination-ip-prefix "
revflowClassifier+=$sourceIP
revflowClassifier+="/32 --logical-source-port proxy_port FC1_REV_1 "

echo "Reverse flowclassifier is =================>$revflowClassifier"
$revflowClassifier
#Create Chain:
openstack sfc port chain create  --port-pair-group PG2_REV_1 --flow-classifier FC1_REV_1 PC1_REV_1

#Create Static route
setRoute="openstack router set --route destination="
setRoute+=$SFC_NET
setRoute+=",gateway="
setRoute+=$nextHop
setRoute+=" source_router"
echo "Set Route is -------------------->"$setRoute
$setRoute


#Create reverse static route
setrevRoute="openstack router set --route destination="
setrevRoute+=$SOURCE_NET
setrevRoute+=",gateway="
setrevRoute+=$revnextHop
setrevRoute+=" sfc_router"
echo "Rev Set Route is -------------------->"$setrevRoute
$setrevRoute


#Enable port forwarding/add routes in VNF
echo "NIDS Floating Ip is------>"$NIDSfloatingIP
ssh-keygen -R $NIDSfloatingIP

if [ -z `ssh-keygen -F $NIDSfloatingIP` ]; then   ssh-keyscan -H $NIDSfloatingIP >> ~/.ssh/known_hosts; fi
sleep 5
ssh -i key ubuntu@$NIDSfloatingIP sudo dhclient ens4
sleep 5
ssh -i key ubuntu@$NIDSfloatingIP sudo sysctl net.ipv4.ip_forward=1
sleep 5
ssh -i key ubuntu@$NIDSfloatingIP sudo route add $proxyIP ens4

#HAproxy Configuration
echo  -e "\033[33;5;7m.............Configuring haproxy for laod balancing...............\033[0m"
ssh-keygen -R $LBfloatingIP

if [ -z `ssh-keygen -F $LBfloatingIP` ]; then   ssh-keyscan -H $LBfloatingIP >> ~/.ssh/known_hosts; fi
sleep 5

ssh -i key ubuntu@$LBfloatingIP sudo chmod -R 777 /etc/haproxy

conf="frontend firstbalance \n
        bind *:80 \n
        option forwardfor \n
        default_backend webservers \n
backend webservers \n
        balance roundrobin \n
        server webserver1 "
conf+=$destIP
conf+=":80 check \n
        option httpchk \n\n


frontend firstbalance1 \n
        bind *:2001 \n
        option forwardfor \n
        default_backend webservers1 \n
backend webservers1 \n
        balance roundrobin \n
        server webserver1 "
conf+=$destIP
conf+=":2001 check"
cp loadbalancer.conf haproxy.cfg
echo -e  $conf >> haproxy.cfg
scp -i key haproxy.cfg ubuntu@$LBfloatingIP:/etc/haproxy
ssh -i key ubuntu@$LBfloatingIP sudo /etc/init.d/haproxy restart
rm haproxy.cfg

echo  -e "\033[33;5m############################# NOTE ##############################\033[0m"
echo  -e "\033[33;5;7mPlease manually set the LAN port of Pfsense...............\033[0m"
echo  -e "\033[33;5;7m.............Configure snort for detecting traffic...............\033[0m"

