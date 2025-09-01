#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C

API_URL="https://api.coingecko.com/api/v3/simple/price?ids=the-open-network&vs_currencies=rub"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tonrub"
CACHE_FILE="$CACHE_DIR/rate.txt"
CACHE_TTL="${CACHE_TTL:-60}"  # секунд

# Проверка зависимостей
for cmd in curl jq bc; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Ошибка: требуется '$cmd'. Установите и повторите." >&2
    exit 1
  }
done

usage() {
  cat <<EOF
Использование:
  ${0##*/} rate          — показать текущий курс (1 TON в RUB)
  ${0##*/} ton-to-rub AMOUNT — конвертировать AMOUNT TON в RUB
  ${0##*/} rub-to-ton AMOUNT — конвертировать AMOUNT RUB в TON
  ${0##*/} graph         — показать график курса за текущий год

EOF
}

# Получение исторических данных за текущий год
get_yearly_data() {
  local end_date=$(date +%s)
  # Начало текущего года (1 января)
  local current_year=$(date +%Y)
  local start_date=$(date -d "${current_year}-01-01" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${current_year}-01-01" +%s 2>/dev/null)
  
  # CoinGecko API для исторических данных (market_chart/range)
  local history_url="https://api.coingecko.com/api/v3/coins/the-open-network/market_chart/range?vs_currency=rub&from=${start_date}&to=${end_date}"
  
  echo "Загрузка данных за ${current_year} год..." >&2
  
  local response=$(curl -sS --fail "$history_url" 2>/dev/null) || {
    echo "Ошибка: не удалось получить исторические данные." >&2
    return 1
  }
  
  # Извлекаем цены и временные метки
  echo "$response" | jq -r '.prices[] | "\(.[0]/1000) \(.[1])"' | {
    local prev_month=""
    local month_sum=0
    local month_count=0
    
    while read -r timestamp price; do
      local current_month=$(date -d "@$timestamp" "+%Y-%m" 2>/dev/null || date -r "$timestamp" "+%Y-%m" 2>/dev/null)
      
      if [[ "$current_month" != "$prev_month" ]]; then
        if [[ -n "$prev_month" ]] && [[ $month_count -gt 0 ]]; then
          local avg_price=$(bc -l <<< "scale=2; $month_sum / $month_count")
          echo "$prev_month $avg_price"
        fi
        prev_month="$current_month"
        month_sum="$price"
        month_count=1
      else
        month_sum=$(bc -l <<< "$month_sum + $price")
        month_count=$((month_count + 1))
      fi
    done
    
    # Последний месяц
    if [[ $month_count -gt 0 ]]; then
      local avg_price=$(bc -l <<< "scale=2; $month_sum / $month_count")
      echo "$prev_month $avg_price"
    fi
  }
}

# Получение названия месяца
get_month_name() {
  case "$1" in
    01|1) echo "Янв" ;;
    02|2) echo "Фев" ;;
    03|3) echo "Мар" ;;
    04|4) echo "Апр" ;;
    05|5) echo "Май" ;;
    06|6) echo "Июн" ;;
    07|7) echo "Июл" ;;
    08|8) echo "Авг" ;;
    09|9) echo "Сен" ;;
    10) echo "Окт" ;;
    11) echo "Ноя" ;;
    12) echo "Дек" ;;
    *) echo "???" ;;
  esac
}

# График за текущий год с осями
show_yearly_graph() {
  local yearly_cache="$CACHE_DIR/yearly_data.txt"
  
  # Проверяем кеш годовых данных (обновляем раз в час)
  if [[ -f "$yearly_cache" ]]; then
    local cache_age=$(($(date +%s) - $(stat -f%m "$yearly_cache" 2>/dev/null || stat -c%Y "$yearly_cache" 2>/dev/null || echo 0)))
    if [[ $cache_age -lt 3600 ]]; then  # 1 час
      local mins=$((cache_age/60))
      echo "Используем кешированные данные (обновлено ${mins} мин. назад)" >&2
    else
      get_yearly_data > "$yearly_cache" || return 1
    fi
  else
    mkdir -p "$CACHE_DIR"
    get_yearly_data > "$yearly_cache" || return 1
  fi
  
  if [[ ! -s "$yearly_cache" ]]; then
    echo "Нет данных для отображения" >&2
    return 1
  fi
  
  local current_year=$(date +%Y)
  echo
  echo "                    График курса TON/RUB за ${current_year} год"
  echo
  
  # Находим min/max для масштабирования
  local max=$(awk '{print $2}' "$yearly_cache" | sort -n | tail -1)
  local min=$(awk '{print $2}' "$yearly_cache" | sort -n | head -1)
  local range=$(bc -l <<< "$max - $min")
  
  if (( $(bc <<< "$range == 0") )); then
    range=1
  fi
  
  # Высота графика
  local graph_height=20
  
  # Создаем массив для хранения данных
  local -a month_names
  local -a month_numbers
  local -a prices
  local i=0
  
  while read -r year_month price; do
    local month="${year_month#*-}"
    # Убираем ведущий ноль и сохраняем как число
    month=$((10#$month))
    month_numbers[i]="$month"
    month_names[i]=$(get_month_name "$month")
    prices[i]="$price"
    ((i++))
  done < "$yearly_cache"
  
  local num_months=${#prices[@]}
  
  # Проверка на пустой массив
  if [[ $num_months -eq 0 ]]; then
    echo "Нет данных для отображения графика" >&2
    return 1
  fi
  
  # Рисуем график по строкам (сверху вниз)
  echo "  RUB │"
  
  for ((row=graph_height; row>=0; row--)); do
    # Вычисляем значение для этой строки с шагом 10
    local row_value=$(bc -l <<< "scale=0; $min + ($range * $row / $graph_height)")
    
    # Рисуем метку оси Y каждые 2 строки вместо 5
    if [[ $((row % 2)) -eq 0 ]]; then
      printf "%5.0f │" "$row_value"
    else
      printf "      │"
    fi
    
    # Рисуем точки графика
    for ((col=0; col<num_months; col++)); do
      local price="${prices[col]}"
      local bar_height=$(bc <<< "scale=0; ($price - $min) * $graph_height / $range")
      
      # Определяем символ для отображения
      local symbol=" "
      if [[ $bar_height -eq $row ]]; then
        # Точка графика
        symbol="●"
      elif [[ $bar_height -gt $row ]]; then
        # Столбец ниже точки
        if [[ $col -eq 0 ]]; then
          symbol="█"
        else
          local prev_price="${prices[$((col-1))]}"
          local prev_height=$(bc <<< "scale=0; ($prev_price - $min) * $graph_height / $range")
          
          # Линия между точками
          if (( row <= bar_height && row <= prev_height )); then
            symbol="█"
          elif (( row <= bar_height || row <= prev_height )); then
            symbol="▒"
          else
            symbol=" "
          fi
        fi
      fi
      
      # Цвет для точки
      if [[ $col -gt 0 ]] && [[ "$symbol" != " " ]]; then
        local prev_price="${prices[$((col-1))]}"
        if (( $(bc <<< "$price > $prev_price") )); then
          echo -en "\033[32m$symbol\033[0m"  # зеленый для роста
        elif (( $(bc <<< "$price < $prev_price") )); then
          echo -en "\033[31m$symbol\033[0m"  # красный для падения
        else
          echo -en "\033[33m$symbol\033[0m"  # желтый без изменений
        fi
      else
        echo -n "$symbol"
      fi
      
      # Пробелы между столбцами  
      echo -n "   "
    done
    echo
  done
  
  # Ось X
  printf "      └"
  for ((i=0; i<num_months*4; i++)); do
    echo -n "─"
  done
  echo "→"
  
  # Подписи месяцев (ось X) - теперь цифрами
  printf "       "
  for ((i=0; i<num_months; i++)); do
    printf "%-4d" "${month_numbers[i]}"
  done
  echo " Месяцы"
  echo
  
  # Легенда с значениями - без вертикальных линий как в статистике
  echo "  Данные по месяцам ${current_year} года:"
  echo "  ────────────────────────────────────────────"
  
  for ((i=0; i<num_months; i++)); do
    local price="${prices[i]}"
    local month="${month_names[i]}"
    
    # Изменение относительно предыдущего месяца
    if [[ $i -gt 0 ]]; then
      local prev_price="${prices[$((i-1))]}"
      local change=$(bc -l <<< "$price - $prev_price")
      local percent=$(bc -l <<< "scale=2; $change * 100 / $prev_price")
      
      if (( $(bc <<< "$change > 0") )); then
        printf "  %3s: %6.2f ₽  \033[32m↑%.2f (%.2f%%)\033[0m\n" "$month" "$price" "$change" "$percent"
      elif (( $(bc <<< "$change < 0") )); then
        printf "  %3s: %6.2f ₽  \033[31m↓%.2f (%.2f%%)\033[0m\n" "$month" "$price" "${change#-}" "${percent#-}" 
      else
        printf "  %3s: %6.2f ₽  →0.00 (0.00%%)\n" "$month" "$price"
      fi
    else
      printf "  %3s: %6.2f ₽  (начало года)\n" "$month" "$price"
    fi
  done
  echo
  
  # Общая статистика
  local first_price="${prices[0]}"
  # Исправляем получение последнего элемента для старых версий bash
  local last_index=$((num_months - 1))
  local last_price="${prices[$last_index]}"
  
  local total_change=$(bc -l <<< "$last_price - $first_price")
  local total_percent=$(bc -l <<< "scale=2; $total_change * 100 / $first_price")
  local avg=$(awk '{sum+=$2; count++} END {printf "%.2f", sum/count}' "$yearly_cache")
  
  echo "  Статистика за ${current_year} год:"
  echo "  ────────────────────────────────────────────"
  printf "  Минимум:  %.2f ₽\n" "$min"
  printf "  Максимум: %.2f ₽\n" "$max"
  printf "  Среднее:  %.2f ₽\n" "$avg"
  printf "  Размах:   %.2f ₽\n" "$range"
  
  if (( $(bc <<< "$total_change > 0") )); then
    printf "  Итог:     \033[32m↑%.2f ₽ (+%.2f%%)\033[0m\n" "$total_change" "$total_percent"
  elif (( $(bc <<< "$total_change < 0") )); then
    printf "  Итог:     \033[31m↓%.2f ₽ (%.2f%%)\033[0m\n" "${total_change#-}" "${total_percent#-}"
  else
    printf "  Итог:     →0.00 ₽ (0.00%%)\n"
  fi
  echo
}

# Получение текущего курса с кешем
get_rate() {
  local rate now
  
  mkdir -p "$CACHE_DIR"
  
  if [[ -f "$CACHE_FILE" ]]; then
    now=$(date +%s)
    local cache_time
    if [[ "$OSTYPE" == "darwin"* ]]; then
      cache_time=$(stat -f%m "$CACHE_FILE" 2>/dev/null || echo 0)
    else
      cache_time=$(stat -c%Y "$CACHE_FILE" 2>/dev/null || echo 0)
    fi
    
    if (( now - cache_time < CACHE_TTL )); then
      cat "$CACHE_FILE"
      return 0
    fi
  fi
  
  rate=$(curl -sS --fail "$API_URL" 2>/dev/null | jq -r '."the-open-network".rub // empty') || {
    [[ -f "$CACHE_FILE" ]] && cat "$CACHE_FILE" && return 0
    echo "Ошибка: не удалось получить курс." >&2
    exit 1
  }
  
  if [[ "$rate" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "$rate" | tee "$CACHE_FILE"
  else
    exit 1
  fi
}

# Проверка и нормализация числа
check_amount() {
  local amt="${1//,/.}"
  amt="${amt// /}"
  
  if [[ ! "$amt" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "Ошибка: некорректная сумма: $1" >&2
    exit 1
  fi
  echo "$amt"
}

# Основная логика
[[ $# -eq 0 ]] && { usage; exit 1; }

case "$1" in
  rate)
    rate=$(get_rate)
    printf "💰 1 TON = %.2f RUB\n" "$rate"
    ;;
  ton-to-rub)
    [[ ${2:-} ]] || { echo "Укажите сумму в TON." >&2; exit 1; }
    rate=$(get_rate)
    amt=$(check_amount "$2")
    result=$(bc -l <<< "$amt * $rate")
    printf "%.2f TON = %.2f RUB (курс: %.2f)\n" "$amt" "$result" "$rate"
    ;;
  rub-to-ton)
    [[ ${2:-} ]] || { echo "Укажите сумму в RUB." >&2; exit 1; }
    rate=$(get_rate)
    amt=$(check_amount "$2")
    result=$(bc -l <<< "$amt / $rate")
    printf "%.2f RUB = %.2f TON (курс: %.2f)\n" "$amt" "$result" "$rate"
    ;;
  graph)
    show_yearly_graph
    ;;
  *)
    usage
    exit 1
    ;;
esac


