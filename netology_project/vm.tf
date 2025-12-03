# Считать данные об образе ОС:

data "yandex_compute_image" "ubuntu_2204_lts" {
  family = "ubuntu-2204-lts"
}

# Создать ВМ bastion:

resource "yandex_compute_instance" "bastion" {
  name        = "bastion"
  hostname    = "bastion"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores         = 2
    memory        = 1
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 10
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")
    serial-port-enable = 1
  }

  scheduling_policy { preemptible = true }

  network_interface {
    subnet_id          = yandex_vpc_subnet.develop_a.id
    nat                = true   # ← ЭТО делает инстанс публичным!
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.bastion.id]
  }
}

# Создать ВМ web_a:

resource "yandex_compute_instance" "web_a" {
  name        = "web-a"
  hostname    = "web-a"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"


  resources {
    cores         = 2
    memory        = 1
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 10
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")
    serial-port-enable = 1
  }

  scheduling_policy { preemptible = true }

  network_interface {
    subnet_id          = yandex_vpc_subnet.develop_a.id
    nat                = false										# Только приватный IP
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.web_sg.id]
  }
}

# Создать ВМ web_b:

resource "yandex_compute_instance" "web_b" {
  name        = "web-b"
  hostname    = "web-b"
  platform_id = "standard-v3"
  zone        = "ru-central1-b"

  resources {
    cores         = 2
    memory        = 1
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 10
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")
    serial-port-enable = 1
  }

  scheduling_policy { preemptible = true }

  network_interface {
    subnet_id          = yandex_vpc_subnet.develop_b.id
    nat                = false
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.web_sg.id]

  }
}

# Создать целевую группу:

resource "yandex_alb_target_group" "web-target-group" {
  name = "web-targets"
  
  target {
    subnet_id  = yandex_compute_instance.web_a.network_interface[0].subnet_id
    ip_address    = yandex_compute_instance.web_a.network_interface[0].ip_address
  }
  
  target {
    subnet_id  = yandex_compute_instance.web_b.network_interface[0].subnet_id  
    ip_address    = yandex_compute_instance.web_b.network_interface[0].ip_address
  }
}

# Создать группу бэкендов:

resource "yandex_alb_backend_group" "web-backend-group" {
  name = "web-backend-group"
  
  http_backend {
    name = "http-backend"
    weight = 1
    port = 80
    target_group_ids = [yandex_alb_target_group.web-target-group.id]
    
    healthcheck {
      timeout = "3s"
      interval = "2s"
      healthy_threshold = 2
      unhealthy_threshold = 2
      healthcheck_port = 80
      http_healthcheck {
        path = "/"
      }
    }
    
    # Отключить HTTP/2 и сложные настройки
    http2 = false
  }
}

# Создать HTTP-роутер:

resource "yandex_alb_http_router" "http-router" {
  name          = "http-router"
  labels        = {
    tf-label    = "tf-label-value"
    empty-label = ""
  }
}

resource "yandex_alb_virtual_host" "my-virtual-host" {
  name           = "alb-virtual-host"
  http_router_id = yandex_alb_http_router.http-router.id

  rate_limit {
    all_requests {
      per_second = 300
      # или per_minute = <количество_запросов_в_минуту>
    }
    requests_per_ip {
      per_second = 300
      # или per_minute = <количество_запросов_в_минуту>
    }
  }

  route {
    name                      = "route-1"
    
    http_route {
      http_match {
				path {
          exact = "/"
        }
			}
      
      http_route_action {
        backend_group_id  = yandex_alb_backend_group.web-backend-group.id
      }
    }
  }
}

# Создать L7-balancer

resource "yandex_alb_load_balancer" "http-balancer" {
  name        = "http-balancer"
  network_id  = yandex_vpc_network.develop.id
  # security_group_ids = [yandex_vpc_security_group.alb_sg.id]

  allocation_policy {
    location {
      zone_id   = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.develop_a.id
    }
    
    location {
      zone_id   = "ru-central1-b"
      subnet_id = yandex_vpc_subnet.develop_b.id
    }
  }

  # HTTP-обработчик
  listener {
    name = "http-listener"
    endpoint {
      address {
        external_ipv4_address {
        }
      }
      ports = [80]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.http-router.id
      }
    }
  }
}

# Создание файла host.ini 
resource "local_file" "inventory" {
  content  = <<-XYZ
  [bastion]
  ${yandex_compute_instance.bastion.network_interface.0.nat_ip_address}

  [webservers]
  ${yandex_compute_instance.web_a.network_interface.0.ip_address}				# 0 - первый интерфейс машины
  ${yandex_compute_instance.web_b.network_interface.0.ip_address}
  
  [prometheus]
  ${yandex_compute_instance.prometheus.network_interface.0.ip_address}

  [grafana]
  ${yandex_compute_instance.grafana.network_interface.0.ip_address}

  [elastic]
  ${yandex_compute_instance.elastic.network_interface.0.ip_address}

  [kibana]
  ${yandex_compute_instance.kibana.network_interface.0.ip_address}
  
  [monitoring_targets:children]  # Группа всех хостов для мониторинга
  webservers
  prometheus
  
  [logging_targets:children]     # Группа всех хостов для сбора логов
  webservers
  elastic
  
  [webservers:vars]
  ansible_ssh_common_args='-o ProxyCommand="ssh -p 22 -W %h:%p -q mike@${yandex_compute_instance.bastion.network_interface.0.nat_ip_address}"'		# Для того, чтобы попасть на web-сервера надо пойти через бастион
  
  [prometheus:vars]
  ansible_ssh_common_args='-o ProxyCommand="ssh -p 22 -W %h:%p -q mike@${yandex_compute_instance.bastion.network_interface.0.nat_ip_address}"'		# Для того, чтобы попасть на prometheus надо пойти через бастион

  [grafana:vars]
  ansible_ssh_common_args='-o ProxyCommand="ssh -p 22 -W %h:%p -q mike@${yandex_compute_instance.bastion.network_interface.0.nat_ip_address}"'

  [elastic:vars]
  ansible_ssh_common_args='-o ProxyCommand="ssh -p 22 -W %h:%p -q mike@${yandex_compute_instance.bastion.network_interface.0.nat_ip_address}"'

  [kibana:vars]
  ansible_ssh_common_args='-o ProxyCommand="ssh -p 22 -W %h:%p -q mike@${yandex_compute_instance.bastion.network_interface.0.nat_ip_address}"'
  XYZ
  filename = "./hosts.ini"				# Результат записывается в данный файл
}

# Создание ВМ для Prometheus:

resource "yandex_compute_instance" "prometheus" {
  name        = "prometheus"
  hostname    = "prometheus"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"  # ← Та же зона что и web-a

  resources {
    cores         = 2
    memory        = 4  # Prometheus требует больше памяти
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 20   # Увеличить диск для метрик
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")
    serial-port-enable = 1
  }

  scheduling_policy { preemptible = true }

  network_interface {
    subnet_id          = yandex_vpc_subnet.develop_a.id  # ← Та же подсеть что и web-a
    nat                = false
    security_group_ids = [yandex_vpc_security_group.LAN.id]
  }
}

# Создание ВМ для Grafana

resource "yandex_compute_instance" "grafana" {
  name = "grafana"
  hostname = "grafana"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 10
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")
    serial-port-enable = 1
  }

  scheduling_policy { preemptible = true }

  network_interface {
    subnet_id          = yandex_vpc_subnet.develop_a.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.grafana_sg.id]
  }

}

# Создание ВМ для Elasticsearch
resource "yandex_compute_instance" "elastic" {
  name        = "elastic"
  hostname    = "elastic"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores         = 4
    memory        = 8
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 50
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")
    serial-port-enable = 1
  }

  scheduling_policy { preemptible = true }

  network_interface {
    subnet_id          = yandex_vpc_subnet.develop_a.id
    nat                = false
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.elastic_sg.id]
  }
}

# Создание ВМ для Kibana
resource "yandex_compute_instance" "kibana" {
  name        = "kibana"
  hostname    = "kibana"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores         = 4
    memory        = 10
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204_lts.image_id
      type     = "network-hdd"
      size     = 20
    }
  }

  metadata = {
    user-data          = file("./cloud-init.yml")
    serial-port-enable = 1
  }

  scheduling_policy { preemptible = true }

  network_interface {
    subnet_id          = yandex_vpc_subnet.develop_a.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.LAN.id, yandex_vpc_security_group.kibana_sg.id]
  }
}

