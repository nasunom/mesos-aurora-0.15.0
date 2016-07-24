#!/bin/bash

setup_master() {
  # zookeeper
  rm -rf /var/lib/zookeeper/version-2
  service zookeeper start

  # mesos-master
  exec /usr/sbin/mesos-master \
    --zk=zk://$ZK_HOST:2181/mesos/master \
    --ip=$MY_HOST \
    --work_dir=/var/lib/mesos \
    --quorum=1 \
    >/tmp/mesos.log 2>&1 &

  export LD_LIBRARY_PATH=/usr/lib/jvm/java-8-openjdk-amd64/jre/lib/amd64/server
  mkdir -p /var/db/aurora
  mesos-log initialize --path="/var/db/aurora"

  # aurora-scheduler
  export GLOG_v=0
  export LIBPROCESS_PORT=8083
  export LIBPROCESS_IP=$ZK_HOST
  export DIST_DIR=/aurora/dist
  export JAVA_OPTS='-Djava.library.path=/usr/lib -Xdebug -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address=5005'
  export GLOBAL_CONTAINER_MOUNTS=${GLOBAL_CONTAINER_MOUNTS:-'/opt:/opt:rw'}

  cd $DIST_DIR/install/aurora-scheduler
  exec ./bin/aurora-scheduler \
    -cluster_name=devcluster \
    -hostname=$MY_HOST \
    -http_port=8081 \
    -native_log_quorum_size=1 \
    -zk_endpoints=localhost:2181 \
    -mesos_master_address=zk://localhost:2181/mesos/master \
    -serverset_path=/aurora/scheduler \
    -native_log_zk_group_path=/aurora/replicated-log \
    -native_log_file_path=/var/db/aurora \
    -backup_dir=/var/lib/aurora/backups \
    -thermos_executor_path=$DIST_DIR/thermos_executor.pex \
    -thermos_executor_flags="--announcer-ensemble localhost:2181" \
    -global_container_mounts=$GLOBAL_CONTAINER_MOUNTS \
    -allowed_container_types=MESOS,DOCKER \
    -use_beta_db_task_store=true \
    -enable_h2_console=true \
    -tier_config=/aurora/src/main/resources/org/apache/aurora/scheduler/tiers.json \
    -receive_revocable_resources=true \
  >/tmp/aurora_scheduler-console.log 2>&1 &
}

setup_slave() {
  # mesos resources (CPUs, Mem:MB, Disk:MB)
  export MESOS_CPUS=${MESOS_CPUS:-33}
  export MESOS_MEM=${MESOS_MEM:-90000}
  export MESOS_DISK=${MESOS_DISK:-100000}

  # docker daemon
  bash /usr/local/bin/dockerd-entrypoint.sh >/tmp/docker.log 2>&1 &
  (( timeout = 60 + SECONDS ))
  until docker info >/dev/null 2>&1
  do
    if (( SECONDS >= timeout )); then
      echo 'Timed out trying to connect to internal docker host.' >&2
      exit 1
    fi
    sleep 1
  done

  # mesos-slave
  rm -rf /var/lib/mesos/*
  exec /usr/sbin/mesos-slave \
    --master=zk://$ZK_HOST:2181/mesos/master \
    --ip=$MY_HOST \
    --hostname=$MY_HOST \
    --resources="cpus:$MESOS_CPUS;mem:$MESOS_MEM;disk:$MESOS_DISK" \
    --work_dir="/var/lib/mesos" \
    --containerizers=docker,mesos \
    >/tmp/mesos.log 2>&1 &

  # thermos-observer
  exec /aurora/dist/thermos_observer.pex \
    --port=1338 \
    --log_to_disk=NONE \
    --log_to_stderr=google:INFO \
    >/tmp/thermos_observer-console.log 2>&1 &
}

export MY_HOST_IF=${MY_HOST_IF:-eth0}
export MY_HOST=$(ifconfig $MY_HOST_IF|grep 'inet addr'|awk '{print $2}'|awk -F: '{print $2}')
export ZK_HOST=${ZK_HOST:-$MY_HOST}
hostname $MY_HOST \
  && sed "1i $MY_HOST    $MY_HOST" /etc/hosts > /tmp/hosts \
  && cp /tmp/hosts /etc/hosts

if [ "$ZK_HOST" != "$MY_HOST" ]; then
  echo "setup mesos-slave"
  setup_slave
else
  echo "setup mesos-master"
  setup_master
fi

tail -f /tmp/mesos.log

