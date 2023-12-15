# Airgap Kit

This repo's scope is very simple. The mechanism uses a yaml file for configuration to declare the Rancher and cert-manager versions that you wish to grab, those helm charts, and any additional helm charts you wish to grab. While `Hauler` is immensely flexible, this keeps it simple in order to pull the images you want for a Rancher install.

For a deeper dive into `Hauler`, check the [docs](https://rancherfederal.github.io/hauler-docs/)

# Requirements
* Linux OS like Ubuntu (WSL2 is fine in Windows)
* make
* helm

To install `Hauler` and other dependencies, use `make install`. For the sake of `yq`, it only installs the linux version currently but can easily be edited to pull the darwin binary if using MacOS.

# Pull
The Makefile builds a manifest which is fed into `Hauler` which pulls everything down into the local store. Under hood it uses ytt templating and yq to generate a manifest. After this it will export the images into a zst archive at the location of your choosing. To do this, use `make pull`.

Be aware the pull can be large. Because of this, there is a regex filter in the file [filter.list](./filter.list) to cut down on the size. The list as it sits is pretty complete but has most RKE1 components and other unneeded items removed. The default images size is about 110GB and with filtering it is shrunk to about 62GB.

# Serve
Copy the archive into your airgap and then install `Hauler` within the airgap. You can just copy the binaries if Linux version is the same. See `/usr/local/bin/hauler`.

Installing `Harbor` as a container registry onto `Harvester` is a chicken/egg problem. Obviously `Harbor` cannot self-reference itself in order to start when it comes to container images. So we will use `Hauler` to host the images temporarily so `Harbor` can start. 

Ensure the [config.yaml](./config.yaml) properly defines your airgapped workstation's IP address as well as the ingress configuration and the location of your archive created in previous steps. Note that these DNS (harbor and notary) entries will need to point at your `Harvester` cluster nodes.

Once your are sure the configuration is correct, use the `serve` target:
```console
> make serve
```

TODO: configuring harbor to use insecure temporary registry

This should run as a background daemon process. Following that, you can then install Harbor. Ensure your kube context on your workstation is set for the `Harvester` cluster. If you have not pulled down this kubeconfig, you will need to do so. The download location is in the `Harvester` UI under the `Support` page. Use the `harbor` target to install Harbor with the tweaked helm values:

```console
> make harbor
```

# Push
Copy the archive into your airgap and then install `Hauler` within the airgap. You can just copy the binaries if Linux version is the same. See `/usr/local/bin/hauler`.

First sync the image archive into your local store. This can take some time;
```console
> hauler store load -f myarchive.tar.zst
```

Then copy the local store to a remote registry. 
```console
> hauler store copy registry://<registry-url> -u admin -p Harbor12345
```

# Consuming Harbor
With this installation, Harbor is configured to use a generated certificate. As a result, this cert will not be part of the public CA chain of trust and will come up as 'insecure' unless other provisions are taken into account when creating your RKE2 cluster for Rancher.

In order to do this, RKE2 looks for a `/etc/rancher/rke2/registries.yaml` file upon boot and uses it for any extra configuration of the underhood containerd runtime.

Adding the below will mark your harbor registry as 'insecure' but will allow RKE2 to use it when pulling images. Do not use this in production. A production deployment would inject the real certificate as part of the Harbor installation so there would be no insecure configuation.

The `/etc/rancher/rke2/registries.yaml` file should look like this:
```yaml
configs:
  "harbor.myurl.com":
    tls:
      insecure_skip_verify: true
```

# TODO
* grab install script from github
* grab rke2 tarball files

