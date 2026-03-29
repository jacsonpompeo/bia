#!/bin/bash
CLUSTER="cluster-bia-alb"
SERVICE="service-bia-alb"
REGION="us-east-1"

# Captura task definition atual para rollback
CURRENT_TASK_DEF=$(aws ecs describe-services \
  --cluster $CLUSTER --services $SERVICE \
  --region $REGION \
  --query 'services[0].taskDefinition' --output text)

echo "Task definition atual (rollback): $CURRENT_TASK_DEF"

# Build e push da nova imagem
./build-alb.sh

# Deploy
echo "Iniciando deploy no $CLUSTER / $SERVICE..."
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --force-new-deployment \
  --region $REGION

# Aguarda estabilização
echo "Aguardando estabilização do serviço..."
aws ecs wait services-stable \
  --cluster $CLUSTER \
  --services $SERVICE \
  --region $REGION

if [ $? -eq 0 ]; then
  echo "Deploy concluído com sucesso!"
else
  echo "Deploy falhou! Iniciando rollback para: $CURRENT_TASK_DEF"
  aws ecs update-service \
    --cluster $CLUSTER \
    --service $SERVICE \
    --task-definition $CURRENT_TASK_DEF \
    --region $REGION
  echo "Rollback iniciado. Verifique o status do serviço."
  exit 1
fi
