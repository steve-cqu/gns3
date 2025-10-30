# Administration Operations on GNS3 VM

The following are operations that may be used to administer the GNS3 VM. This is normally not performed by students. It is included mainly as reference.

# GNS3 VM Menu

# Shell Access

# Docker

Many of the nodes in GNS3 are Docker containers. The Docker images are created in the GNS3 VM, and then when a node is added to a Project, a new container is created. For example, there is a ``alpinenode`` Docker image included in the GNS3 VM. This is associated with node types such as ``Linux Host``, ``Linux Router``, and ``VPN Router``. If a project includes 3 Linux Hosts and 2 Linux Routers, then there will be 5 Docker containers based on the ``alpinenode`` image.

For more information about the Docker images included in GNS VM provided by CQU, see the [server setup](../server/README.md). The Dockerfiles for some images are included in the [server/docker](../server/docker/) directory.

## View Docker Images

Example of viewing the Docker images:
```
gns3@gns3vm:~$ docker image ls
REPOSITORY              TAG       IMAGE ID       CREATED        SIZE
cqugns3/ipv6node        latest    3c9bdb1bd45b   23 hours ago   581MB
cqugns3/alpinenode      latest    0794100b0abe   23 hours ago   575MB
gns3/kalilinux          latest    6b02465051af   4 days ago     2.79GB
cqugns3/auth-kerberos   latest    43804f60145f   4 days ago     592MB
adosztal/net_toolbox    latest    e64c6cb1db86   4 days ago     417MB
<none>                  <none>    719e96603c8f   4 days ago     575MB
gns3/webterm            latest    0613820dbb8c   4 days ago     719MB
gns3/ipterm             latest    cdac0973b22c   4 days ago     110MB
gns3/ipterm-base        latest    6a4a0a97c785   4 days ago     110MB
gns3/openvswitch        latest    a6d394ee2034   4 days ago     17.5MB
```

Note that the size is not necessarily the size on disk. Docker layering allows one image to be built from another, where only the differences between the two images are stored on disk. 

## View Docker Disk Usage

Example of viewing Docker disk usage by images as well as containers:
```
gns3@gns3vm:~$ docker system df -v
Images space usage:

REPOSITORY              TAG       IMAGE ID       CREATED        SIZE      SHARED SIZE   UNIQUE SIZE   CONTAINERS
cqugns3/ipv6node        latest    3c9bdb1bd45b   23 hours ago   581MB     575.2MB       6.089MB       1
cqugns3/alpinenode      latest    0794100b0abe   23 hours ago   575MB     575.2MB       0B            5
gns3/kalilinux          latest    6b02465051af   4 days ago     2.79GB    0B            2.786GB       0
cqugns3/auth-kerberos   latest    43804f60145f   4 days ago     592MB     575.2MB       17.26MB       0
adosztal/net_toolbox    latest    e64c6cb1db86   4 days ago     417MB     0B            416.6MB       0
<none>                  <none>    719e96603c8f   4 days ago     575MB     575.2MB       0B            1
gns3/webterm            latest    0613820dbb8c   4 days ago     719MB     110.2MB       608.3MB       0
gns3/ipterm             latest    cdac0973b22c   4 days ago     110MB     110.2MB       169B          0
gns3/ipterm-base        latest    6a4a0a97c785   4 days ago     110MB     110.2MB       0B            0
gns3/openvswitch        latest    a6d394ee2034   4 days ago     17.5MB    8.322MB       9.225MB       0

Containers space usage:

CONTAINER ID   IMAGE                       COMMAND                  LOCAL VOLUMES   SIZE      CREATED        STATUS                      NAMES
73ded2812afb   cqugns3/alpinenode:latest   "/gns3/init.sh /bin/…"   4               4.65kB    23 hours ago   Exited (137) 22 hours ago   naughty_turing
0cf1dfc42c33   cqugns3/alpinenode:latest   "/gns3/init.sh /bin/…"   4               4.91kB    23 hours ago   Exited (137) 22 hours ago   peaceful_einstein
...
```

The output continues. The top list shows the actual disk usage of the images. Node for example that ``alpinenode``, ``auth-kerberos`` and ``ipv6node`` all shared a base image (``alpinenode``). So the total disk space used across the three is about 600 MB (not 1748 MB).

Each container also stores select files (e.g., files in ``/etc`` directory). These are typically quite small for the use cases in GNS3.




