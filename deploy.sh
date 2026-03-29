#!/bin/bash
set -e

# ─── Configurações ────────────────────────────────────────────────────────────
CLUSTER="cluster-bia"
SERVICE="service-bia"
TASK_FAMILY="task-def-bia"
ECR_REGISTRY="794038236031.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="bia"
REGION="us-east-1"

# ─── Help ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Uso: $(basename "$0") [COMANDO] [OPÇÕES]

COMANDOS:
  deploy [COMMIT_HASH]   Faz build, push e deploy da imagem com a tag do commit.
                         Se COMMIT_HASH não for informado, usa o HEAD do git.

  rollback <REVISÃO>     Faz rollback para uma task definition específica.
                         Ex: $(basename "$0") rollback task-def-bia:5
                         Ex: $(basename "$0") rollback 5

  list                   Lista as últimas 10 revisões da task definition.

  status                 Exibe o status atual do serviço no ECS.

  help                   Exibe esta mensagem.

EXEMPLOS:
  $(basename "$0") deploy
  $(basename "$0") deploy a1b2c3d
  $(basename "$0") rollback 5
  $(basename "$0") list
  $(basename "$0") status
EOF
  exit 0
}

# ─── Funções auxiliares ───────────────────────────────────────────────────────
ecr_login() {
  echo "[INFO] Autenticando no ECR..."
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"
}

wait_for_stable() {
  echo "[INFO] Aguardando serviço estabilizar..."
  aws ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION"
  echo "[INFO] Serviço estável."
}

# ─── Comandos ─────────────────────────────────────────────────────────────────
cmd_deploy() {
  local COMMIT_HASH="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo "manual")}"
  local IMAGE_URI="$ECR_REGISTRY/$ECR_REPO:$COMMIT_HASH"

  echo "[INFO] Iniciando deploy | commit: $COMMIT_HASH"

  ecr_login

  echo "[INFO] Fazendo build da imagem..."
  docker build -t "$ECR_REPO" .
  docker tag "$ECR_REPO:latest" "$IMAGE_URI"
  docker tag "$ECR_REPO:latest" "$ECR_REGISTRY/$ECR_REPO:latest"

  echo "[INFO] Fazendo push para o ECR..."
  docker push "$IMAGE_URI"
  docker push "$ECR_REGISTRY/$ECR_REPO:latest"

  echo "[INFO] Registrando nova task definition com imagem $IMAGE_URI..."
  # Obtém a task definition atual e substitui a imagem
  TASK_DEF_JSON=$(aws ecs describe-task-definition \
    --task-definition "$TASK_FAMILY" \
    --region "$REGION" \
    --query 'taskDefinition' \
    --output json)

  NEW_TASK_DEF=$(echo "$TASK_DEF_JSON" \
    | jq --arg IMAGE "$IMAGE_URI" \
        'del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy)
         | .containerDefinitions[0].image = $IMAGE')

  NEW_REVISION=$(aws ecs register-task-definition \
    --region "$REGION" \
    --cli-input-json "$NEW_TASK_DEF" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

  echo "[INFO] Nova task definition: $NEW_REVISION"

  echo "[INFO] Atualizando serviço ECS..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$NEW_REVISION" \
    --region "$REGION" \
    --output text --query 'service.serviceArn' > /dev/null

  wait_for_stable
  echo "[OK] Deploy concluído! Imagem: $IMAGE_URI | Task: $NEW_REVISION"
}

cmd_rollback() {
  local TARGET="$1"
  [[ -z "$TARGET" ]] && { echo "[ERRO] Informe a revisão. Ex: $0 rollback 5"; exit 1; }

  # Aceita tanto "5" quanto "task-def-bia:5"
  if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    TARGET="${TASK_FAMILY}:${TARGET}"
  fi

  echo "[INFO] Iniciando rollback para: $TARGET"

  TASK_ARN=$(aws ecs describe-task-definition \
    --task-definition "$TARGET" \
    --region "$REGION" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text 2>/dev/null) || { echo "[ERRO] Task definition '$TARGET' não encontrada."; exit 1; }

  echo "[INFO] Atualizando serviço para $TASK_ARN..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TASK_ARN" \
    --region "$REGION" \
    --output text --query 'service.serviceArn' > /dev/null

  wait_for_stable
  echo "[OK] Rollback concluído! Task ativa: $TASK_ARN"
}

cmd_list() {
  echo "[INFO] Últimas 10 revisões de $TASK_FAMILY:"
  aws ecs list-task-definitions \
    --family-prefix "$TASK_FAMILY" \
    --sort DESC \
    --max-items 10 \
    --region "$REGION" \
    --query 'taskDefinitionArns[]' \
    --output table
}

cmd_status() {
  echo "[INFO] Status do serviço $SERVICE no cluster $CLUSTER:"
  aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION" \
    --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount,TaskDef:taskDefinition}' \
    --output table
}

# ─── Roteamento ───────────────────────────────────────────────────────────────
case "${1:-help}" in
  deploy)   cmd_deploy "$2" ;;
  rollback) cmd_rollback "$2" ;;
  list)     cmd_list ;;
  status)   cmd_status ;;
  help|--help|-h) usage ;;
  *) echo "[ERRO] Comando desconhecido: $1"; usage ;;
esac
