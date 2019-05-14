I have been playing around with Kubernetes for a couple months now.
I have setup MiniKube and OpenShift on a Single Fedora Node that runs on a Mac Mini.
I’ve taken the Certified Kubernetes Administrator course on Linux Academy, which sets up a small cluster, and I have just finished The Linux Academy course Kubernetes the Hard Way, which follows Kelsey Hightower’s paper Kubernetes The Hard Way.
This course was fantastic, and I highly recommend it if you really want to learn about how Kubernetes is put together.
Up until taking this course, every tutorial or class I had taken used kubeadm, ansible scripts,
or some other script that was a wrapper around one of those.
Kubernetes the hard way really showed me what all these scripts were doing, and the building blocks of how kubernetes is put together.

So I have decided it will be a good project to put together a Raspberry Pi cluster following Kubernetes The Hardway setup.
I will publish a series of posts documenting this installation.

The Setup:
## I have 7 Raspberry Pi 3 B+, a 8-port NetGear Gigabit switch, a GeauxRobot 7 layer Dogbone Pi rack, and 7 Samsung 32GB mini SD Cards.
I have 3 Raspberry Pi (two Pi 3B+ and one Pi2), a 5-port switch with USB-Power source,
a Pi rack, and 2 64GB and 1 32GB USB-Flash drive and 1 micro SD Cards for booting the Pi 2.

The plan is to build 2 Master Controllers, 3 Worker Nodes,
and so two nodes shall be hermaphrodite while on only does heavy lifting

One master will also be the load balancer.
Each Master will run etcd, kube-apiserver, kube-scheduler, and kube-controller-manager.
Each worker will run a kubelet, kube-proxy, kube-dns, and use docker as the container platform.

This is a bit of a change from Kubernetes the hard way, since that used containerd as the container platform.
However, that is one of the things I learned that interested me the most. In Kubernetes,
it is possible to switch out some of these building blocks, and I’m interested in figuring out how that is done.


Provisioning the Raspberry Pi’s

Download the Raspbian Lite image and flash it to an SD Card. I use Etcher.io to flash the cards, but there are plenty of other applications and ways to accomplish this.
After flashing the SD Card, run touch ssh in the boot partition to enable SSHD, to be able to run the servers in a headless mode.
If you don’t have a ssh key, run ssh-keygen and follow the instructions on screen to generate one
Next, in the rootfs of the SD card, run
$ mkdir home/pi/.ssh
$ cat ~/.ssh/id_rsa.pub > home/pi/.ssh/authorized_keys
$ chmod 600 home/pi/.ssh/authorized_keys
Unmount the SD Card, put it in the Pi and boot.
There are a number of ways to figure out the IP of your Pi, i.e. login to your router/DHCP server, and a number of scanning tools. I prefer to use nmap.
$ nmap -p 22 192.168.1.0/24

Nmap scan report for raspberrypi.local (10.1.1.42)
Host is up (0.0037s latency).
SSH into your Pi with the user pi
If you setup your sshkey properly, you will not be prompted for a password.

Run sudo raspi-config In Network Options, change the hostname to “pinode2”, and in Advanced Options expand the root filesystem. Then Reboot. When it comes back up you should now be able to ssh pi@pinode2

Setup a second virtual interface to create a private network between the Raspberry Pi’s. These will be the addresses used in all the configurations of the cluster.

$ sudo vi /etc/network/interfaces

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp

auto eth0:1
allow-hotplug eth0:1
iface eth0:1 inet static
  address 10.240.0.1
  netmask 255.255.255.0
  gateway 10.0.0.1

# Turn off swap

$ sudo dphys-swapfile swapoff && \
$ sudo dphys-swapfile uninstall && \
$ sudo update-rc.d dphys-swapfile remove
change the boot parameters

$ sudo vi /boot/cmdline.txt

cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory
Repeat these steps on the other 6 pi’s using the following host names:

pinode1
k8s-master-3.k8s.daveevans.us
pinode3
pinode1
k8s-node-3.k8s.daveevans.us
pinode2
After completing all the installations and configurations, my servers have the below names and IP addresses.

Hostname	Public IP	Private IP
pinode2	10.1.1.42	10.240.0.1
pinode1	10.1.1.41	10.240.0.2
k8s-master-3.k8s.daveevans.us	192.168.1.22	10.0.0.12
pinode3	192.168.1.23	10.240.0.3
pinode1	10.1.1.41	10.240.0.2
k8s-node-3.k8s.daveevans.us	192.168.1.25	10.0.0.15
pinode2	10.1.1.42	10.240.0.1
---
After the setup of the raspberry pi servers in part 1, I have the hostnames and IPs in the table below. We now have to create a CA and certificates for all the different pieces of the cluster. Then create kubeconfigs for the different components to use to connect to the cluster, and distribute everything out to the nodes. This seems like a really long post, but you will see that its a lot of rinse and repeat commands. 

All the commands below are run on my local linux machine.

Hostname	Public IP	Private IP
pinode2	10.1.1.42	10.240.0.1
pinode1	10.1.1.41	10.240.0.2
k8s-master-3.k8s.daveevans.us	192.168.1.22	10.0.0.12
pinode3	192.168.1.23	10.240.0.3
pinode1	10.1.1.41	10.240.0.2
k8s-node-3.k8s.daveevans.us	192.168.1.25	10.0.0.15
pinode2	10.1.1.42	10.240.0.1

Setup our local linux machine (alfa 10.1.1.10)

First, we need to install cfssl which will be used to create all the certificates that we will create.

$ wget -q --show-progress --https-only --timestamping \
  https://pkg.cfssl.org/R1.2/cfssl_linux-amd64 \
  https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
$ chmod +x cfssl_linux-amd64 cfssljson_linux-amd64
$ sudo mv cfssl_linux-amd64 /usr/local/bin/cfssl
$ sudo mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
$ cfssl version
Next, we have to install kubectl that we will use to remotely connect to the cluster later, but in this post we will use it to create the kubeconfigs for the cluster components.

$ wget https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/amd64/kubectl
$ chmod +x kubectl
$ sudo mv kubectl /usr/local/bin/
$ kubectl version --client
Creating the CA and cluster certificates.

Create the CA using the command set below. You will see a pattern to all these commands. The first part(s) creates a JSON file that are then fed into the cfssl command to generate the certificates. I also suggest running these in a seperate directory as it creates a bunch of files. I created ~/k8s-pi and cd into it

$ {

cat > ca-config.json << EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json << EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

}
Create Admin certificates which will be used to connect remotely to the cluster.

{

cat > admin-csr.json << EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

}
Create API Server Certs. Below we first set a CERT_HOSTNAME environment variable that lists all the IPs and hostnames that could be used to connect to the API servers.

$ CERT_HOSTNAME=10.32.0.1,10.240.0.1,pinode2,10.240.0.2,pinode1,10.0.0.12,k8s-master-3.k8s.daveevans.us,127.0.0.1,localhost,kubernetes.default


$ {

cat > kubernetes-csr.json << EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${CERT_HOSTNAME} \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

}
Create Controller Certs

$ {

cat > kube-controller-manager-csr.json << EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

}
Create Scheduler Certs

$ {

cat > kube-scheduler-csr.json << EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler

}
Create Client Certificates. We create environment variables that list the hostname and IPs of the worker nodes, then create the certificates for each node. One important note, we are using the private IP address that was setup on the second virtual address for all the IP connectivity.

$ WORKER0_HOST=pinode3
$ WORKER0_IP=10.240.0.3
$ WORKER1_HOST=pinode1
$ WORKER1_IP=10.240.0.2
$ WORKER2_HOST=k8s-node-3.k8s.daveevans.us
$ WORKER2_IP=10.0.0.15

$ {
cat > ${WORKER0_HOST}-csr.json << EOF
{
  "CN": "system:node:${WORKER0_HOST}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${WORKER0_IP},${WORKER0_HOST} \
  -profile=kubernetes \
  ${WORKER0_HOST}-csr.json | cfssljson -bare ${WORKER0_HOST}

cat > ${WORKER1_HOST}-csr.json << EOF
{
  "CN": "system:node:${WORKER1_HOST}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${WORKER1_IP},${WORKER1_HOST} \
  -profile=kubernetes \
  ${WORKER1_HOST}-csr.json | cfssljson -bare ${WORKER1_HOST}

cat > ${WORKER2_HOST}-csr.json << EOF
{
  "CN": "system:node:${WORKER2_HOST}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${WORKER2_IP},${WORKER2_HOST} \
  -profile=kubernetes \
  ${WORKER2_HOST}-csr.json | cfssljson -bare ${WORKER2_HOST}
}
Create Proxy Certificate

{

cat > kube-proxy-csr.json << EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy

}
Create Service Key Pair

$ {

cat > service-account-csr.json << EOF
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Baden-Wuerteberg",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Boeblingen"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  service-account-csr.json | cfssljson -bare service-account

}
Create Encryption Key

$ ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

$ cat > encryption-config.yaml << EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
Create Admin kubeconfig using the CA and Admin certs we just created.

{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

  kubectl config set-credentials admin \
    --client-certificate=admin.pem \
    --client-key=admin-key.pem \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

  kubectl config use-context default --kubeconfig=admin.kubeconfig
}
Create kube-controller-manager kubeconfig

{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=kube-controller-manager.pem \
    --client-key=kube-controller-manager-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
}
Create kube-scheduler kubeconifg

{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate=kube-scheduler.pem \
    --client-key=kube-scheduler-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
}
Create kube-proxy kubeconfig

{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_ADDRESS}:6443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials system:kube-proxy \
    --client-certificate=kube-proxy.pem \
    --client-key=kube-proxy-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
}
Create the worker node kubeconfigs. Here a for loop is used to create the individual kubeconfigs for each of the nodes.

for instance in pinode3 pinode1 k8s-node-3.k8s.daveevans.us; do
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=${instance}.pem \
    --client-key=${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
done
Distribute the certs and kubeconfigs

$ scp ca.pem \
      ca-key.pem \
      kube-controller-manager-key.pem \
      kube-controller-manager.pem \
      kube-controller-manager-key.kubeconfig \
      kubernetes-key.pem kubernetes.pem \
      kube-scheduler-key.pem \
      kube-scheduler.pem \
      kube-scheduler.kubeconfig \
      admin-key.pem admin.pem \
      admin.kubeconfig \
      pi@pinode2:~/

$ scp ca.pem \
      ca-key.pem \
      kube-controller-manager-key.pem \
      kube-controller-manager.pem \
      kube-controller-manager-key.kubeconfig \
      kubernetes-key.pem kubernetes.pem \
      kube-scheduler-key.pem \
      kube-scheduler.pem \
      kube-scheduler.kubeconfig \
      admin-key.pem admin.pem \
      admin.kubeconfig \
      pi@pinode1:~/

$ scp ca.pem \
      ca-key.pem \
      kube-controller-manager-key.pem \
      kube-controller-manager.pem \
      kube-controller-manager-key.kubeconfig \
      kubernetes-key.pem kubernetes.pem \
      kube-scheduler-key.pem \
      kube-scheduler.pem \
      kube-scheduler.kubeconfig \
      admin-key.pem admin.pem \
      admin.kubeconfig \ 
      pi@k8s-master-3.k8s.daveevans.us:~/
      
$ scp kube-proxy-key.pem \
      kube-proxy.pem \
      kube-proxy.kubeconfig \
      ca.pem \
      pinode3-key.pem \
      pinode3.pem \
      pinode3.kubeconfig \
      pi@pinode3:~/
      
$ scp kube-proxy-key.pem \
      kube-proxy.pem \
      kube-proxy.kubeconfig \
      ca.pem \
      pinode1-key.pem \
      pinode1.pem \
      pinode1.kubeconfig \
      pi@pinode1:~/

$ scp kube-proxy-key.pem \
      kube-proxy.pem \
      kube-proxy.kubeconfig \
      ca.pem \
      k8s-node-3.k8s.daveevans.us-key.pem \
      k8s-node-3.k8s.daveevans.us.pem \
      k8s-node-3.k8s.daveevans.us.kubeconfig \
      pi@k8s-node-3.k8s.daveevans.us:~/
      
---
In this part of the series, we will setup the 3 master nodes. Starting by installing the Ectd, then the kube-apiserver, kube-controller-manager, and kube-scheduler. In a bit of a departure from the original Kubernetes the Hard Way, I will not setup the the local nginx proxy on each master node to proxy the healthz endpoint. This was done because of a limitation of the load balancers on Google Cloud, but is not needed with using nginx as the load balancer.

Hostname	Public IP	Private IP
pinode2	10.1.1.42	10.240.0.1
pinode1	10.1.1.41	10.240.0.2
k8s-master-3.k8s.daveevans.us	192.168.1.22	10.0.0.12
pinode3	192.168.1.23	10.240.0.3
pinode1	10.1.1.41	10.240.0.2
k8s-node-3.k8s.daveevans.us	192.168.1.25	10.0.0.15
pinode2	10.1.1.42	10.240.0.1
Install Etcd

This presented my first challenge of this project. Etcd does have builds for arm64; however, the Raspberry Pi 3 B+ running raspbian run the armv7l kernel. You can see this be running arch on your raspberry pi. Luckily, Etcd is written in go, which makes it pretty easy to cross compile code.

Setup each master node for creating Etcd config.

On k8s-master-1:

$ ETCD_NAME=pinode2
$ INTERNAL_IP=10.240.0.1
$ INITIAL_CLUSTER=pinode2=https://10.240.0.1:2380,pinode1=https://10.240.0.2:2380,k8s-master-3.k8s.daveevans.us=https://10.0.0.12:2380
On k8s-master-2:

ETCD_NAME=pinode1
INTERNAL_IP=10.240.0.2
INITIAL_CLUSTER=pinode2=https://10.240.0.1:2380,pinode1=https://10.240.0.2:2380,k8s-master-3.k8s.daveevans.us=https://10.0.0.12:2380
On k8s-master-3:

ETCD_NAME=k8s-master-3.k8s.daveevans.us
INTERNAL_IP=10.0.0.12
INITIAL_CLUSTER=pinode2=https://10.240.0.1:2380,pinode1=https://10.240.0.2:2380,k8s-master-3.k8s.daveevans.us=https://10.0.0.12:2380
Cross compile Etcd binaries on local machine, and distribute to the master nodes.

On my local machine:

$ go get github.com/etcd-io/etcd
$ env GOOS=linux GOARCH=arm go build -o ~/build-etcd/etcd github.com/etcd-io/etcd
$ env GOOS=linux GOARCH=arm go build -o ~/build-etcd/etcdctl github.com/etcd-io/etcd/etcdctl
$ scp ~/build-etcd/etcd* pi@pinode2:~/
$ scp ~/build-etcd/etcd* pi@pinode1:~/
$ scp ~/build-etcd/etcd* pi@pinode1:~/
Move the binaries into place and create the necessary configuration directories.

On All 3 Masters:

$ sudo mv ~/etcd* /usr/local/bin/
$ sudo mkdir -p /etc/etcd /var/lib/etcd
$ sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/
Create etcd systemd unit file. One note on the unit file. I had to add the Environment='ETCD_UNSUPPORTED_ARCH=arm' line to get the service to start, since arm is an unsupported architecture.

$ cat << EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Environment='ETCD_UNSUPPORTED_ARCH=arm'
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ${INITIAL_CLUSTER} \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
Start and enable Etcd

$ sudo systemctl daemon-reload
$ sudo systemctl enable etcd
$ sudo systemctl start etcd
Install the Control Plane binaries

All of these commands need to be run on each of the master servers.

Download and place the control plane binaries

$ sudo mkdir -p /etc/kubernetes/config

$ wget -q --show-progress --https-only --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/arm/kube-apiserver" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/arm/kube-controller-manager" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/arm/kube-scheduler" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/arm/kubectl"

$ chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl

$ sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
Configure kube-apiserver service. On each Master, replace the INTERNAL_IP variable with the hosts private IP.

$ sudo mkdir -p /var/lib/kubernetes/

$ sudo cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
  service-account-key.pem service-account.pem \
  encryption-config.yaml /var/lib/kubernetes/


$ INTERNAL_IP=10.240.0.1
$ CONTROLLER0_IP=10.240.0.1
$ CONTROLLER1_IP=10.240.0.2
$ CONTROLLER2_IP=10.0.0.12


$ cat << EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=Initializers,NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --enable-swagger-ui=true \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://$CONTROLLER0_IP:2379,https://$CONTROLLER1_IP:2379,https://$CONTROLLER2_IP:2379 \\
  --event-ttl=1h \\
  --experimental-encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --kubelet-https=true \\
  --runtime-config=api/all \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2 \\
  --kubelet-preferred-address-types=InternalIP,InternalDNS,Hostname,ExternalIP,ExternalDNS
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
Configure kube-controller-manager service

$ sudo cp kube-controller-manager.kubeconfig /var/lib/kubernetes/

$ cat << EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --address=0.0.0.0 \\
  --cluster-cidr=10.200.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
Configure kube-scheduler service.

$ sudo cp kube-scheduler.kubeconfig /var/lib/kubernetes/

$ cat << EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: componentconfig/v1alpha1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF


$ cat << EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
Start all services and ensure they are running.

$ sudo systemctl daemon-reload
$ sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
$ sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
$ sudo systemctl status kube-apiserver kube-controller-manager kube-scheduler
Create RBAC config for the cluster components.

$ cat << EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF

$ cat << EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF
Create Nginx Load balancer for the kube-apiserver

This should be run on the load balancer server

Install nginx

$ sudo apt-get install -y nginx
$ sudo systemctl enable nginx
$ sudo mkdir -p /etc/nginx/tcpconf.d
Edit /etc/nginx/nginx.conf adding the below line at the bottom.

   include /etc/nginx/tcpconf.d/*;
Create an nginx config file

$ CONTROLLER0_IP=10.240.0.1
$ CONTROLLER1_IP=10.240.0.2
$ CONTROLLER2_IP=10.0.0.12

$ cat << EOF | sudo tee /etc/nginx/tcpconf.d/kubernetes.conf
stream {
    upstream kubernetes {
        server $CONTROLLER0_IP:6443;
        server $CONTROLLER1_IP:6443;
        server $CONTROLLER2_IP:6443;
    }

    server {
        listen 6443;
        listen 443;
        proxy_pass kubernetes;
    }
}
EOF
Start the nginx server

$ sudo systemctl start nginx
---
Now its time to setup the worker nodes. This is where I will deviate the most from the original Kubernetes the Hard Way, as I plan to change the container runtime from containerd to docker.

Install and Configure Docker

These commands should be run on each worker node.

Update apt package index

Install packages to allow apt to use a repository over HTTPS:

$ sudo apt-get install \
     apt-transport-https \
     ca-certificates \
     curl \
     gnupg2 \
     software-properties-common
Add Docker’s official GPG key:

$ curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
Use the following command to set up the stable repository.

$ echo "deb [arch=armhf] https://download.docker.com/linux/debian \
     $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list
Update the apt package index

Install the latest docker-ce version

$ sudo apt-get install docker-ce
There are a couple configuration changes we need to make to docker. We want to remove the iptables rules that docker created, and set it not to control iptables. The kube-proxy will be responsible for that. In addtion, we want to get rid of the docker network bridge.

$ iptables -t nat -F
$ ip link set docker0 down
$ ip link delete docker0
$ sudo vi /etc/default/docker
...
DOCKER_OPTS="--iptables=false --ip-masq=false"
...
Install Kubernetes services

Install binaries

$ sudo apt-get -y install socat conntrack ipset

$ wget -q --show-progress --https-only --timestamping \
  https://github.com/containernetworking/plugins/releases/download/v0.6.0/cni-plugins-arm-v0.6.0.tgz \
  https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/arm/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/arm/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.12.0/bin/linux/arm/kubelet

$ sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

$ chmod +x kubectl kube-proxy kubelet

$ sudo mv kubectl kube-proxy kubelet /usr/local/bin/

$ sudo tar -xvf cni-plugins-arm-v0.6.0.tgz -C /opt/cni/bin/
Configure Kubelet

$ HOSTNAME=$(hostname)
$ sudo mv ${HOSTNAME}-key.pem ${HOSTNAME}.pem /var/lib/kubelet/
$ sudo mv ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
$ sudo mv ca.pem /var/lib/kubernetes/

$ cat << EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS: 
  - "10.32.0.10"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${HOSTNAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${HOSTNAME}-key.pem"
EOF


$ cat << EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --v=2 \\
  --hostname-override=${HOSTNAME} \\
  --allow-privileged=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
Configure kube-proxy

$ sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig


$ cat << EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
EOF



$ cat << EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
Start and enable services

$ sudo systemctl daemon-reload
$ sudo systemctl enable kubelet kube-proxy
$ sudo systemctl start kubelet kube-proxy

$ sudo systemctl status kubelet kube-proxy
Check to see if nodes registered. On one of the master nodes run:

$ kubectl get nodes
NAME                          STATUS     ROLES    AGE   VERSION
pinode3   NotReady   <none>   12m   v1.12.0
pinode1   NotReady   <none>   32s   v1.12.0
k8s-node-3.k8s.daveevans.us   NotReady   <none>   12m   v1.12.0
---
Kubernetes on Raspberry Pi, The Hard Way - Part 5
Dave EvansOctober 28, 2018
5 minutes read

Kubernetes on Raspberry Pi, The Hard Way - Part 1
Kubernetes on Raspberry Pi, The Hard Way - Part 2
Kubernetes on Raspberry Pi, The Hard Way - Part 3
Kubernetes on Raspberry Pi, The Hard Way - Part 4
The final part of this journey is to setup the networking. Which in the end is pretty straight forward, but did cause me some grief. I had trouble getting kube-dns working. I tried switching the CNI to flannel and use core-dns, but did not have much luck. Finally, switched it back, but discovered the images in the kube-dns deployment were amd64 rather than arm.

On all 3 worker nodes, we need to configure IP forwarding

sudo sysctl net.ipv4.conf.all.forwarding=1
echo "net.ipv4.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
Next, deploy weave network plugin. Run the below on one of the master nodes.

kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')&env.IPALLOC_RANGE=10.200.0.0/16"
Deploy kube-dns. I had to edit the kube-dns.yaml from https://storage.googleapis.com/kubernetes-the-hard-way/kube-dns.yaml to replace the amd64 images to arm images.

$ cat << EOF | kubectl apply -f -
# Copyright 2016 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.32.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
spec:
  # replicas: not specified here:
  # 1. In order to make Addon Manager do not reconcile this replicas parameter.
  # 2. Default is 1.
  # 3. Will be tuned in real time if DNS horizontal auto-scaling is turned on.
  strategy:
    rollingUpdate:
      maxSurge: 10%
      maxUnavailable: 0
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      volumes:
      - name: kube-dns-config
        configMap:
          name: kube-dns
          optional: true
      containers:
      - name: kubedns
        image: gcr.io/google_containers/k8s-dns-kube-dns-arm:1.14.7
        resources:
          # TODO: Set memory limits when we've profiled the container for large
          # clusters, then set request = limit to keep this container in
          # guaranteed class. Currently, this container falls into the
          # "burstable" category so the kubelet doesn't backoff from restarting it.
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        livenessProbe:
          httpGet:
            path: /healthcheck/kubedns
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /readiness
            port: 8081
            scheme: HTTP
          # we poll on pod startup for the Kubernetes master service and
          # only setup the /readiness HTTP server once that's available.
          initialDelaySeconds: 3
          timeoutSeconds: 5
        args:
        - --domain=cluster.local.
        - --dns-port=10053
        - --config-dir=/kube-dns-config
        - --v=2
        env:
        - name: PROMETHEUS_PORT
          value: "10055"
        ports:
        - containerPort: 10053
          name: dns-local
          protocol: UDP
        - containerPort: 10053
          name: dns-tcp-local
          protocol: TCP
        - containerPort: 10055
          name: metrics
          protocol: TCP
        volumeMounts:
        - name: kube-dns-config
          mountPath: /kube-dns-config
      - name: dnsmasq
        image: gcr.io/google_containers/k8s-dns-dnsmasq-nanny-arm:1.14.7
        livenessProbe:
          httpGet:
            path: /healthcheck/dnsmasq
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - -v=2
        - -logtostderr
        - -configDir=/etc/k8s/dns/dnsmasq-nanny
        - -restartDnsmasq=true
        - --
        - -k
        - --cache-size=1000
        - --no-negcache
        - --log-facility=-
        - --server=/cluster.local/127.0.0.1#10053
        - --server=/in-addr.arpa/127.0.0.1#10053
        - --server=/ip6.arpa/127.0.0.1#10053
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        # see: https://github.com/kubernetes/kubernetes/issues/29055 for details
        resources:
          requests:
            cpu: 150m
            memory: 20Mi
        volumeMounts:
        - name: kube-dns-config
          mountPath: /etc/k8s/dns/dnsmasq-nanny
      - name: sidecar
        image: gcr.io/google_containers/k8s-dns-sidecar-arm:1.14.7
        livenessProbe:
          httpGet:
            path: /metrics
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --v=2
        - --logtostderr
        - --probe=kubedns,127.0.0.1:10053,kubernetes.default.svc.cluster.local,5,SRV
        - --probe=dnsmasq,127.0.0.1:53,kubernetes.default.svc.cluster.local,5,SRV
        ports:
        - containerPort: 10054
          name: metrics
          protocol: TCP
        resources:
          requests:
            memory: 20Mi
            cpu: 10m
      dnsPolicy: Default  # Don't use cluster DNS.
      serviceAccountName: kube-dns
EOF
Testing the cluster

$ kubectl get pods -n kube-system
NAME                        READY   STATUS    RESTARTS   AGE
kube-dns-6b99655b85-4bjl2   3/3     Running   0          47m
weave-net-nzqrk             2/2     Running   4          74m
weave-net-wtl2z             2/2     Running   4          74m
weave-net-wxrlk             2/2     Running   4          74m
$ cat << EOF | kubectl apply -f -
 apiVersion: apps/v1
 kind: Deployment
 metadata:
   name: nginx
 spec:
   selector:
     matchLabels:
       run: nginx
   replicas: 2
   template:
     metadata:
       labels:
         run: nginx
     spec:
       containers:
       - name: my-nginx
         image: nginx
         ports:
         - containerPort: 80
EOF
deployment.apps/nginx created

$ kubectl get pods
NAME                    READY   STATUS    RESTARTS   AGE
nginx-bcc4746c8-4m9j4   1/1     Running   0          53s
nginx-bcc4746c8-nvddx   1/1     Running   0          53s

$ kubectl expose deployment/nginx
service/nginx exposed

$ kubectl get svc nginx
NAME    TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
nginx   ClusterIP   10.32.0.37   <none>        80/TCP    59s
On Worker Node:

pi@k8s-node-2:~ $ curl -I  http://10.32.0.37
HTTP/1.1 200 OK
Server: nginx/1.15.5
Date: Mon, 29 Oct 2018 01:53:05 GMT
Content-Type: text/html
Content-Length: 612
Last-Modified: Tue, 02 Oct 2018 14:49:27 GMT
Connection: keep-alive
ETag: "5bb38577-264"
Accept-Ranges: bytes
---
Summary

This was a fun project, and I’m looking forward to continuing to play with this cluster. I have a FreeNAS which I plan to serve up NFS from and experiment with some persistent storage. Plus, setting this up, I now understand what Ingress services are used for.