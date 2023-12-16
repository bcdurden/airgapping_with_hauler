# Airgap Kit
This repo's scope is very simple. The mechanism uses a yaml file for configuration to declare the Rancher and cert-manager versions that you wish to grab, those helm charts, and any additional helm charts you wish to grab. While `Hauler` is immensely flexible, this keeps it simple in order to pull the images you want for a Rancher install.

For a deeper dive into `Hauler`, check the [docs](https://rancherfederal.github.io/hauler-docs/)

Given that Harbor is a common registry used within an infrastructure, I have built an example of how it can be packaged using Hauler and deployed into a Kubernetes cluster prior to copying all Rancher images into it. This avoids the chicken/egg problem.

# Caveats
The Harbor install docs below do not describe a production-grade deployment of Harbor. A specific work-around is in play here using node affinities that will not scale to production clusters that require HA Harbor or an external DB. However, this repo does not architect you into a corner that requires a rewrite. It provides the tools necessary to take that next step and stands close to but still behind the grey line between solution and product.

# Requirements
* Linux OS like Ubuntu (WSL2 is fine in Windows)
* make
* helm

To install `Hauler` and other dependencies, use `make install`. For the sake of `yq`, it only installs the linux version currently but can easily be edited to pull the darwin binary if using MacOS.

# Config
Edit the [config.yaml](./config.yaml) file and ensure the values map to your desired environment.

# Package
First the packaging step. After performing these steps, you will have two archives, one for Rancher and one for Harbor. You will need to also copy this repo as you will use it to push the applications into your airgap.

## Package Rancher
The `Makefile` builds a manifest which is fed into `Hauler` which pulls everything down into the local store. Under hood it uses ytt templating and yq to generate a manifest. After this it will export the images into a zst archive at the location of your choosing. To do this, use `make package-rancher`.

Be aware the pull can be large. Because of this, there is a regex filter in the file [filter.list](./filter.list) to cut down on the size. The list as it sits is pretty complete but has most RKE1 components and other unneeded items removed. The default images size is about 110GB and with filtering it is shrunk to about 62GB.

## Package Harbor
Installing `Harbor` as a container registry onto `Harvester` or some other Kubernetes distribution is a chicken/egg problem. Obviously `Harbor` cannot self-reference itself in order to start when it comes to container images. So we will use `Hauler` to host the images temporarily so `Harbor` can start. 

The package step for Harbor will build a specific archive for Harbor itself, this includes the chart. The only things for Harbor that you will need to bring into the airgap is the .zst file generated and the Hauler binary.

Perform this packaging step by using the `package-harbor` target:

```console
deathstar@deathstar-F7BSC:~/airgapping_with_hauler$ make package-harbor
===>Packaging Harbor
11:01AM INF syncing [content.hauler.cattle.io/v1alpha1, Kind=Images] to store
11:01AM INF added 'image' to store at [index.docker.io/goharbor/harbor-core:v2.9.0]
11:01AM INF added 'image' to store at [index.docker.io/goharbor/harbor-jobservice:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/harbor-portal:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/registry-photon:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/harbor-registryctl:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/harbor-db:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/harbor-db:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/harbor-db:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/redis-photon:v2.9.0]
11:02AM INF added 'image' to store at [index.docker.io/goharbor/trivy-adapter-photon:v2.9.0]
11:02AM INF added 'chart' to store at [hauler/harbor:1.13.0], with digest [sha256:d9d96f152a17ced0c54b8ead3146760dd3f1e6fada2e8b629d154876322d30c3]
11:02AM INF saved store [/home/deathstar/harbor-store] -> [/home/deathstar/harbor.tar.zst]
```

# Prep Airgap Cluster
Hosting Harbor images temporarily will require a manual configuration within your Kubernetes distribution. If your distro is RKE2/K3S, you can edit the `/etc/rancher/rke2/registries.yaml` file (or create it if it doesn't exist) and then paste the below into it. Please note the IP address used here should be the IP address of your airgapped workstation that will be running `Hauler`. While the entire config is not needed for every node in your cluster, it is easier to just have the same config in each.

```yaml
mirrors:
  10.10.0.50:
    endpoint:
      - "http://10.10.0.50:5000"
configs:
  "10.10.0.50:5000":
    auth:
      username: ""
      password: ""
  "harbor.myurl.com":
    tls:
      insecure_skip_verify: true
```

Ensure the [config.yaml](./config.yaml) properly defines your airgapped workstation's IP address as well as the ingress configuration and the location of your archive created in previous steps. Note that these DNS (harbor and notary) entries will need to point at your `Harvester` cluster nodes or you will need to have entries within `/etc/hosts` on your workstation and all Kubernetes nodes.

## Harvester Prep
If you are using `Harvester` as your target cluster, you cannot edit the `/etc/rancher/rke2/registries.yaml` file as the node filesystem is immutable. However, `Harvester` greatly simplifies this process by introducing a UI element for containerd config that will propogate to all nodes automatically. No ssh needed!

Within Harvester, go to the Advanced->Settings page. There is a `containerd-registry` config item, click the `...` menu to the right and edit this setting. You'll need to add several settings here:
* Within the Mirrors, add your workstation IP and 5000 port number (in my case it is `10.10.0.50:5000`) and set the endpoint to `http://10.10.0.50:5000`. 
  * This setting ensures any cluster reference to the `10.10.0.50:5000` registry will be set to insecure (http) mode.
* In configs, you will need two entries.
  * The first entry is a base entry with your workstation IP and port 5000 added, `10.10.0.50:5000` in my case, every other field can be left blank.
  * Click the `Add Config` button and fill the new one out with your harbor URL `harbor.myurl.com` is my example URL. Ensure the `InsecureSkipVerify` is set to true
  * Keep in mind this last setting is NOT FOR PRODUCTION USE. It is only because we auto-generated a secret here. If we used a trusted cert instead, this entry would not be necessary.

After those entries are done, click `Save` and wait a minute for Harvester to propogate the configuration change to the nodes. You are now finished with prepping Harvester!

# Install
Now the Install Step! You'll want to copy your archives onto your airgap workstation as well as this repo. Place them in the locations you've defined in the [config.yaml](./config.yaml) file or edit it to match their new location.

## Installing Harbor
Installing Harbor must be performed first. Again, please ensure your [config.yaml](./config.yaml) properly defines your airgapped workstation's IP address as well as the ingress configuration and the location of your archive created in previous steps.

Also, ensure you have copied your cluster's kubeconfig file down to your workstation and have either installed it into the default `~/.kube/config` location or set the `KUBECONFIG` environment variable prior to running any commands. If this is for Harvester, you can acquire this file in the `Support` page.

Install Harbor using the `install-harbor` target:

```console
deathstar@deathstar-F7BSC:~/airgapping_with_hauler$ make install-harbor
===>Installing Harbor into your Airgap
=>Creating Affinity Label on your node
node/fulcrum1 not labeled
11:11AM INF loading content from [/home/deathstar/harbor.tar.zst] to [/home/deathstar/harbor-store]
11:11AM INF goharbor/registry-photon:v2.9.0
11:11AM INF goharbor/harbor-jobservice:v2.9.0
11:11AM INF goharbor/harbor-db:v2.9.0
11:11AM INF goharbor/trivy-adapter-photon:v2.9.0
11:11AM INF hauler/harbor:1.13.0
11:11AM INF goharbor/harbor-portal:v2.9.0
11:11AM INF goharbor/redis-photon:v2.9.0
11:11AM INF goharbor/harbor-core:v2.9.0
11:11AM INF goharbor/harbor-registryctl:v2.9.0
11:11AM INF copied artifacts to [127.0.0.1:38827]
WARN[0002] No HTTP secret provided - generated random secret. This may cause problems with uploads if multiple registries are behind a load-balancer. To provide a shared secret, fill in http.secret in the configuration file or set the REGISTRY_HTTP_SECRET environment variable.  go.version=go1.21.5 version=v3.0.0+unknown
INFO[0002] redis not configured                          go.version=go1.21.5 version=v3.0.0+unknown
INFO[0002] Starting upload purge in 20m0s                go.version=go1.21.5 version=v3.0.0+unknown
INFO[0002] using inmemory blob descriptor cache          go.version=go1.21.5 version=v3.0.0+unknown
INFO[0002] listening on [::]:5000                        go.version=go1.21.5 version=v3.0.0+unknown
Release "harbor" does not exist. Installing it now.
INFO[0010] response completed                            go.version=go1.21.5 http.request.host="localhost:5000" http.request.id=e683852c-5107-4a70-b855-1442d3e983de http.request.method=HEAD http.request.remoteaddr="127.0.0.1:56334" http.request.uri=/v2/hauler/harbor/manifests/1.13.0 http.request.useragent=Helm/3.10.1 http.response.contenttype=application/vnd.oci.image.manifest.v1+json http.response.
...
NAME: harbor
LAST DEPLOYED: Sat Dec 16 11:11:26 2023
NAMESPACE: harbor
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
Please wait for several minutes for Harbor deployment to complete.
Then you should be able to visit the Harbor portal at https://harbor.myurl.com
For more details, please visit https://github.com/goharbor/harbor
```

Helm is set to wait until the install has succeeded. You can verify Harbor is up and running in the cluster by inspecting the harbor namespace:

```console
deathstar@deathstar-F7BSC:~/airgapping_with_hauler$ kubectl get po -n harbor
NAME                                 READY   STATUS    RESTARTS        AGE
harbor-core-b68648d67-dcctf          1/1     Running   0               2m40s
harbor-database-0                    1/1     Running   0               2m40s
harbor-jobservice-648dd59d64-85hjh   1/1     Running   3 (2m10s ago)   2m40s
harbor-portal-c7b784d88-fl6dr        1/1     Running   0               2m40s
harbor-redis-0                       1/1     Running   0               2m40s
harbor-registry-679f76f64c-bmpdc     2/2     Running   0               2m40s
harbor-trivy-0                       1/1     Running   0               2m40s
```

Assuming your DNS entries are set, attempt to reach your Harbor instance using a web browser. The default username is `admin` and default password is `Harbor12345`. Keep in mind you'll want to change those post-install. And this configuration of Harbor is not production-grade so do not assume it will scale to a larger environment or run on less permissive clusters.

## Consuming Harbor
With this installation, Harbor is configured to use a generated certificate. As a result, this cert will not be part of the public CA chain of trust and will come up as 'insecure' unless other provisions are taken into account when creating your RKE2 cluster for Rancher.

In order to do this, RKE2 looks for a `/etc/rancher/rke2/registries.yaml` file upon boot and uses it for any extra configuration of the underhood containerd runtime. The config steps mentioned at the top of this document capture the necessary changes for this file. But there are a few things to know about it more appropriate to discuss here.

Adding the below will mark your harbor registry as 'insecure' but will allow RKE2 to use it when pulling images. Do not use this in production. A production deployment would inject the real certificate as part of the Harbor installation so there would be no insecure configuation.

The `/etc/rancher/rke2/registries.yaml` file should look like this:
```yaml
configs:
  "harbor.myurl.com":
    tls:
      insecure_skip_verify: true
```

## Install Rancher Images into Harbor
TODO

# TODO
* grab install script from github
* grab rke2 tarball files

