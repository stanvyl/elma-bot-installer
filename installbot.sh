#!/bin/bash

# Убедимся, что скрипт выполняется с правами суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root"
  exit 1
fi

echo "Установка MicroK8s..."
sudo snap install microk8s --channel=1.21/stable --classic

echo "Включение необходимых дополнений..."
sudo microk8s.enable storage
sudo microk8s.enable dns
sudo microk8s.enable rbac
sudo microk8s.enable ingress
sudo microk8s.enable helm3
sudo microk8s.enable ha-cluster
sudo microk8s.enable metrics-server
sudo microk8s.enable hostpath-storage

# Проверка существования папок перед их созданием
for dir in "/home/elmabot" "/home/certs"; do
  if [ ! -d "$dir" ]; then
    echo "Создание папки $dir..."
    mkdir -p "$dir"
  else
    echo "Папка $dir уже существует, пропускаем создание."
  fi
done

echo "Создание корневого сертификата CA..."
sudo mkdir -p /etc/ssl/private /etc/ssl/certs

# Генерация ключа корневого CA без пароля
sudo openssl genrsa -out /etc/ssl/private/rootCA.key 2048

# Генерация сертификата корневого CA
sudo openssl req -x509 -new -key /etc/ssl/private/rootCA.key -sha256 -days 365 \
  -out /etc/ssl/certs/rootCA.pem -subj "/C=RU/ST=Moscow/L=Moscow/O=ElmaBot Org/OU=IT/CN=elmabot"

echo "Корневой сертификат CA создан."

echo "Создание файла конфигурации v3.ext..."
sudo bash -c 'cat > /etc/ssl/v3.ext <<EOL
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = elmabot
EOL'

echo "Файл конфигурации v3.ext создан."

echo "Создание подписанного сертификата..."
sudo openssl genrsa -out /etc/ssl/private/selfsigned.key 2048
sudo openssl req -new -key /etc/ssl/private/selfsigned.key -out /etc/ssl/certs/selfsigned.csr \
  -subj "/C=RU/ST=Moscow/L/Moscow/O=ElmaBot Org/OU=IT/CN=elmabot"
sudo openssl x509 -req -in /etc/ssl/certs/selfsigned.csr -CA /etc/ssl/certs/rootCA.pem \
  -CAkey /etc/ssl/private/rootCA.key -CAcreateserial -out /etc/ssl/certs/selfsigned.crt \
  -days 365 -sha256 -extfile /etc/ssl/v3.ext

echo "Подписанный сертификат создан."

echo "Установка K9s..."
sudo snap install k9s
sudo ln -s /snap/k9s/current/bin/k9s /snap/bin/

echo "Копирование конфигурации kubectl..."
microk8s kubectl config view --raw > "$HOME/.kube/config"

echo "Создание секрета TLS в Kubernetes..."
microk8s kubectl create secret tls my-tls-secret -n default \
  --key /etc/ssl/private/selfsigned.key \
  --cert /etc/ssl/certs/selfsigned.crt

echo "Секрет my-tls-secret создан в namespace default."

echo "Создание ConfigMap для монтирования сертификата..."
microk8s kubectl create configmap elma-bot-root-ca --from-file=elma-bot-cert.crt=/etc/ssl/certs/selfsigned.crt

echo "Скачивание чартов ELMA Bot..."
CHARTS_URL="https://dl.elma365.com/extensions/elma-bot/master/1.9.1/elma-bot.tar.gz"
CHARTS_DIR="/home/elmabot"

wget -O "$CHARTS_DIR/elma-bot.tar.gz" "$CHARTS_URL"
tar -xzvf "$CHARTS_DIR/elma-bot.tar.gz" -C "$CHARTS_DIR"

echo "Чарты скачаны и распакованы в папку $CHARTS_DIR."

# Цикл подтверждения для первой команды
while true; do
  read -p "Продолжить установку Helm-чарта ELMA Bot DBS? (да/yes или нет/no): " answer
  case $answer in
    [Yy]*|да|Да )
      echo "Выполняется установка Helm-чарта ELMA Bot DBS..."
      microk8s helm3 upgrade --install elma-bot-dbs /home/elmabot/elma-bot-dbs/elma-bot-dbs \
        -f /home/elmabot/elma-bot-dbs/values-dbs.yaml -n default --timeout=30m --wait --debug
      echo "Вывод Pod'ов в namespace default:"
      microk8s kubectl get pods
      break
      ;;
    [Nn]*|нет|Нет )
      echo "Выбран отказ. Повторяю вопрос..."
      ;;
    * )
      echo "Пожалуйста, ответьте да/yes или нет/no."
      ;;
  esac
done

# Цикл подтверждения для второй команды
while true; do
  read -p "Продолжить установку Helm-чарта ELMA Bot? (да/yes или нет/no): " answer
  case $answer in
    [Yy]*|да|Да )
      echo "Выполняется установка Helm-чарта ELMA Bot..."
      microk8s helm3 upgrade --install elmabot /home/elmabot/elma-bot -n default --timeout=30m --wait --debug
      echo "Вывод Pod'ов в namespace default:"
      microk8s kubectl get pods
      break
      ;;
    [Nn]*|нет|Нет )
      echo "Выбран отказ. Повторяю вопрос..."
      ;;
    * )
      echo "Пожалуйста, ответьте да/yes или нет/no."
      ;;
  esac
done

echo "Добавление алиасов для MicroK8s в ~/.bashrc..."
echo "alias mk='microk8s kubectl'" >> ~/.bashrc
echo "alias m='microk8s'" >> ~/.bashrc
source ~/.bashrc

echo "Скрипт завершён."
