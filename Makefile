.SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := world

machine ?= base
build ?= 1
BUILD_PUBLISHER_URL ?= http://gbp/

archive := build.tar.gz
container := $(machine)-root
chroot := docker run \
  --name $(container) \
  --env=BUILD_HOST=$(shell uname -n) \
  --env=BUILD_MACHINE=$(machine) \
  --env=BUILD_NUMBER=$(BUILD_NUMBER) \
  --env FEATURES="-cgroup -ipc-sandbox -mount-sandbox -network-sandbox -pid-sandbox -userfetch -usersync binpkg-multi-instance buildpkg noinfo unmerge-orphans" \
  --cap-add=CAP_SYS_PTRACE \
  --volume /proc:/proc \
  --volume "$(CURDIR)"/Makefile.container:/Makefile.gbp \
  $(container)
  
config := $(notdir $(wildcard $(machine)/configs/*))
config_targets := $(config:=.copy_config)
repos_dir := /var/db/repos
repos := $(shell cat $(machine)/repos)
repos_targets := $(repos:=.add_repo)
stage4 := $(machine)-stage4.tar.xz

# Stage3 image tag to use.  See https://hub.docker.com/r/gentoo/stage3/tags
stage3-config := $(machine)/stage3

# Container platform to use (less the "linux/" part)
platform-config := $(machine)/arch


container: stage3-image := docker.io/gentoo/stage3:$(shell cat $(stage3-config))
container: platform := linux/$(shell cat $(platform-config))
container: $(stage3-config) $(platform-config)  ## Build the container
	-docker rm $(container) || true
	docker create --name $(container) --cap-add=CAP_SYS_PTRACE --env FEATURES="-cgroup -ipc-sandbox -mount-sandbox -network-sandbox -pid-sandbox -userfetch -usersync binpkg-multi-instance buildpkg noinfo unmerge-orphans" $(stage3-image)
	docker commit $(container) $(container)
	touch $@


# Watermark for this build
gbp.json: world
	./gbp-meta.py $(machine) $(build) > $@


%.add_repo: %-repo.tar.gz container
	-docker rm $(container) || true
	docker run --name $(container) $(container) sh -c 'rm -rf $(repos_dir)/$* && mkdir -p $(repos_dir)/$*'
	gzip -cd $(CURDIR)/$< | docker cp - $(container):$(repos_dir)/$*
	docker commit $(container) $(container)
	touch $@


.SECONDEXPANSION:
%.copy_config: dirname = $(subst -,/,$*)
%.copy_config: files = $(shell find $(machine)/configs/$* ! -type l -print)
%.copy_config: $$(files) container
	-docker rm $(container) || true
	docker run --name $(container) $(container) sh -c 'rm -rf /$(dirname) && mkdir -p /$(dirname)'
	docker commit $(container) $(container) && docker rm $(container)
	tar cf - -C "$(CURDIR)"/$(machine)/configs/$* . | docker run -i --name $(container) $(container) tar xvf - -C /$(dirname)
	docker commit $(container) $(container)
	touch $@


chroot: $(repos_targets) $(config_targets)  ## Build the chroot in the container
	-docker rm $(container) || true
	$(chroot) make -C / -f Makefile.gbp cache
	docker commit $(container) $(container)
	touch $@


world: chroot  ## Update @world and remove unneeded pkgs & binpkgs
	-docker rm $(container) || true
	$(chroot) make -C / -f Makefile.gbp world
	docker commit $(container) $(container)
	touch $@


packages: world
	buildah unshare --mount CHROOT=$(container) sh -c 'touch -r $${CHROOT}/var/cache/binpkgs/Packages $@'


container.img: packages
	buildah commit $(container) $(machine):$(build)
	rm -f $@
	buildah push $(machine):$(build) docker-archive:"$(CURDIR)"/$@:$(machine):$(build)


.PHONY: archive
archive: $(archive)  ## Create the build artifact


$(archive): gbp.json
	tar cvf build.tar --files-from /dev/null
	tar --append -f build.tar -C $(machine)/configs .
	buildah copy $(container) gbp.json /var/db/repos/gbp.json
	buildah unshare --mount CHROOT=$(container) sh -c 'tar --append -f build.tar -C $${CHROOT}/var/db repos'
	buildah unshare --mount CHROOT=$(container) sh -c 'tar --append -f build.tar -C $${CHROOT}/var/cache binpkgs'
	rm -f $@
	gzip build.tar


logs.tar.gz: chroot
	tar cvf logs.tar --files-from /dev/null
	buildah unshare --mount CHROOT=$(container) sh -c 'test -d $${CHROOT}/var/tmp/portage && cd $${CHROOT}/var/tmp/portage && find . -name build.log | tar --append -f $(CURDIR)/logs.tar -T-'
	rm -f $@
	gzip logs.tar


emerge-info.txt: chroot
	$(chroot) make -C / -f Makefile.gbp emerge-info > .$@
	mv .$@ $@


push: packages  ## Push artifact (to GBP)
	$(MAKE) machine=$(machine) build=$(build) $(archive)
	gbp --url=$(BUILD_PUBLISHER_URL) pull $(machine) $(build)
	touch $@


.PHONY: %.machine
%.machine: base ?= base
%.machine:
	@if test ! -d $(base); then echo "$(base) machine does not exist!" > /dev/stderr; false; fi
	@if test -d $*; then echo "$* machine already exists!" > /dev/stderr; false; fi
	@if test -e $*; then echo "A file named $* already exists!" > /dev/stderr; false; fi
	cp -r $(base)/. $*/


$(stage4): stage4.excl packages
	buildah unshare --mount CHROOT=$(container) sh -c 'tar -cf $@ -I "xz -9 -T0" -X $< --xattrs --numeric-owner -C $${CHROOT} .'


.PHONY: stage4
stage4: $(stage4)  ## Build the stage4 tarball

machine-list:  ## Display the list of machines
	@for i in *; do test -d $$i/configs && echo $$i; done; true


.PHONY: clean-container
clean-container:  ## Remove the container
	-docker rm $(container) || true
	rm -f container


.PHONY: clean
clean: clean-container  ## Clean project files
	rm -rf build.tar $(archive) container container.img packages world *.add_repo chroot *.copy_config $(stage4) gbp.json push


.PHONY: help
help:  ## Show help for this Makefile
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
