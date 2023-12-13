# Airgap Kit

This repo's scope is very simple. The mechanism uses a yaml file for configuration to declare the Rancher and cert-manager versions that you wish to grab, those helm charts, and any additional helm charts you wish to grab. While `Hauler` is immensely flexible, this keeps it simple in order to pull the images you want for a Rancher install.

For a deeper dive into `Hauler`, check the [docs](https://rancherfederal.github.io/hauler-docs/)

# Requirements
* Linux OS like Ubuntu (WSL2 is fine in Windows)
* make
* helm

To install `Hauler` use `make install`. For the sake of `yq`, it only installs the linux version currently but can easily be edited to pull the darwin binary if using MacOS.

# Pull
The Makefile builds a manifest which is fed into `Hauler` which pulls everything down into the local store. Under hood it uses ytt templating and yq to generate a manifest. After this it will export the images into a zst archive at the location of your choosing. To do this, use `make pull`.

Be aware the pull can be large. Because of this, there is a regex filter in the file [filter.list](./filter.list) to cut down on the size. The list as it sits is pretty complete but has most RKE1 components and other unneeded items removed. The default images size is about 110GB and with filtering it is shrunk to about 62GB.

# Push
Copy the archive into your airgap and then install `Hauler` within the airgap. You can just copy the binaries if Linux version is the same. See `/usr/local/bin/hauler`.

First sync the image archive into your local store. This can take some time;
```console
> hauler store sync -f myarchive.tar.zst
```

Then copy the local store to a remote registry. Be aware that you will need to have signed into the remote registry using `cosign`.
```console
> cosign login -u username -p password <registry-url>
...
> hauler store copy registry://<registry-url>
```


