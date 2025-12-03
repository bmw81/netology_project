# Cоздать облачную сеть:

resource "yandex_vpc_network" "develop" {
  name = "develop-net"
}

# Создать подсеть zone A

resource "yandex_vpc_subnet" "develop_a" {
  name           = "develop-net-ru-central1-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.develop.id
  v4_cidr_blocks = ["10.0.1.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

# Создать подсеть zone B

resource "yandex_vpc_subnet" "develop_b" {
  name           = "develop-net-ru-central1-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.develop.id
  v4_cidr_blocks = ["10.0.2.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

# Создать NAT для выхода в интернет

resource "yandex_vpc_gateway" "nat_gateway" {
  name = "develop-gateway"
  shared_egress_gateway {}
}

# Создать сетевой маршрут для выхода в интернет через NAT

resource "yandex_vpc_route_table" "rt" {
  name       = "develop-route-table"
  network_id = yandex_vpc_network.develop.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

# Security group для bastion (firewall):

resource "yandex_vpc_security_group" "bastion" {
  name       = "bastion-sg"
  network_id = yandex_vpc_network.develop.id
  ingress {
    description    = "Allow 0.0.0.0/0"
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }
  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }

}

# Security group для трафика в локальной сети:

resource "yandex_vpc_security_group" "LAN" {
  name       = "LAN-sg"
  network_id = yandex_vpc_network.develop.id
  ingress {
    description    = "Allow 10.0.0.0/8"
    protocol       = "ANY"
    v4_cidr_blocks = ["10.0.0.0/8"]
    from_port      = 0
    to_port        = 65535
  }
  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }

}

# Security group для web-трафика:

resource "yandex_vpc_security_group" "web_sg" {
  name       = "web-sg"
  network_id = yandex_vpc_network.develop.id

  # Разрешить HTTP от балансировщика
  ingress {
    description       = "Allow HTTP from ALB"
    protocol          = "TCP"
    port              = 80
    security_group_id = yandex_vpc_security_group.alb_sg.id
  }

  # Разрешить SSH только из бастиона
  ingress {
    description       = "Allow SSH from bastion"
    protocol          = "TCP"
    port              = 22
    security_group_id = yandex_vpc_security_group.bastion.id
  }

  # Разрешить весь исходящий трафик
  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Security group для балансировщика (на данный момент не используется): 

resource "yandex_vpc_security_group" "alb_sg" {
  name       = "alb-sg"
  network_id = yandex_vpc_network.develop.id

  # Разрешить ВЕСЬ входящий HTTP (включая health checks)
  ingress {
    description    = "Allow all HTTP traffic"
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Разрешить исходящий трафик к веб-серверам
  egress {
    description    = "Allow to web servers"
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24"]
  }
}

# Security group для Grafana:

resource "yandex_vpc_security_group" "grafana_sg" {
  name       = "grafana-sg"
  network_id = yandex_vpc_network.develop.id

  # Разрешить HTTP/HTTPS из интернета
  ingress {
    description    = "Allow HTTP from internet"
    protocol       = "TCP"
    port           = 3000
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow HTTPS from internet"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Разрешить SSH только из bastion
  ingress {
    description       = "Allow SSH from bastion"
    protocol          = "TCP"
    port              = 22
    security_group_id = yandex_vpc_security_group.bastion.id
  }

  # Разрешить исходящие подключения к Prometheus
  egress {
    description    = "Allow to Prometheus"
    protocol       = "TCP"
    port           = 9090
    v4_cidr_blocks = ["10.0.1.0/24"]  # Подсеть где Prometheus
  }

  # Разрешить исходящий DNS и обновления пакетов
  egress {
    description    = "Allow DNS and updates"
    protocol       = "TCP"
    port           = 53
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow HTTP/HTTPS for updates"
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow HTTPS for updates"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group для Elasticsearch
resource "yandex_vpc_security_group" "elastic_sg" {
  name       = "elastic-sg"
  network_id = yandex_vpc_network.develop.id

  ingress {
    description       = "Allow Elasticsearch from Kibana"
    protocol          = "TCP"
    port              = 9200
    security_group_id = yandex_vpc_security_group.kibana_sg.id
  }

  ingress {
    description       = "Allow SSH from bastion"
    protocol          = "TCP"
    port              = 22
    security_group_id = yandex_vpc_security_group.bastion.id
  }

  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Security group для Kibana
resource "yandex_vpc_security_group" "kibana_sg" {
  name       = "kibana-sg"
  network_id = yandex_vpc_network.develop.id

  ingress {
    description    = "Allow HTTP from internet"
    protocol       = "TCP"
    port           = 5601
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description       = "Allow SSH from bastion"
    protocol          = "TCP"
    port              = 22
    security_group_id = yandex_vpc_security_group.bastion.id
  }

  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}
