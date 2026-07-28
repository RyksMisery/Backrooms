# Lights

> Кодовый источник канона: `modules/lighting_module.gd`. Уровни описывают
> occupancy и допустимые локальные overrides, но не копируют параметры панели,
> источника, AreaLight/bounce или продуктового профиля теней.

## Финальный профиль level_e

С `2026-07-19` продуктовый свет `level_e` — `LF3-11F`: occupancy-priority,
дальние видимые receiver до `20 м`, бюджет `10 + временная 11-я` тень, blur
`2.75`. Он включается при загрузке уровня и не имеет игрового переключателя на
старый свет. `REFERENCE`, `LF3-10J` и `LF3-11P` сохраняются только как профили
A/B-бота и регрессионных проверок. Их наличие в коде не означает поддержку
нескольких продуктовых моделей света.

Лаборатория `light_leak_distance_lab` отдельно испытывает topology segment
guardian. Он фиксирует выбранные штатным LF3 caster и opacity на время
нахождения игрока в одной occupancy-клетке и сбрасывает cache при изменении
топологии. Бюджет `LF3-11F` `10+1` сохраняется. Режим не использует
light/render layers, не меняет источники и не является продуктовым профилем.

В той же лаборатории разрешён отдельный dormant A/B-конструктор downward
SpotLight: он наследует у area bounce цвет, range и shadow-параметры, а угол и
энергию получает только от bot-матрицы. Конструктор не входит в продуктовый
LF3 и не вызывается `level_e`.

Ручной finalist использует канонические экспериментальные константы
`AREA_LIGHT_SPOT_FALLBACK_ANGLE = 70°` и
`AREA_LIGHT_SPOT_FALLBACK_ENERGY_MUL = 8`.

Отклонённый лабораторный hybrid назначал Omni статически:
`(source_index_x + 2 × source_index_z) % 3 == 0`; остальные источники —
Spot. Роль запрещено менять в runtime. Для сетки `7×3` это `7 Omni + 14 Spot`
и меньшая shadow-map стоимость, чем у штатного LF3, но профиль не восстановил
верх стен.

Отклонённый A/B-профиль `bidirectional_spot` использует для каждой панели
постоянные downward/upward SpotLight. Оба источника наследуют канонические
range и shadow-параметры; подбор энергий не дал совпадения всех lit ROI.

Допустимый лабораторный companion-fill использует исходный Omni без тени,
но с range не больше `LIGHT_STEP × CELL`; энергия остаётся параметром A/B.

Bot-only профиль `risk_all_shadow_dp` использует штатные Omni без изменения
света, но задаёт `OmniLight3D.SHADOW_DUAL_PARABOLOID`. Это не новый
продуктовый default до проверки шва, качества и GPU-стоимости.

## LF3 runtime-контракт для новых потребителей

`level_e.gd` и `infinite_corridor_e.gd` остаются неизменяемыми эталонами, на
которых свет был визуально принят. Их локальные реализации не рефакторятся при
переносе канона. Для новых областей и лабораторий `lighting_module.gd`
предоставляет эквивалентный runtime-профиль `LF3-11F`: occupancy-priority,
локальные и дальние frustum-receiver до `20 м`, детерминированный ranking,
бюджет `10 + временная 11-я` тень и fade `6…14 м` либо `6…20 м` для caster,
связанного с дальним receiver.

Runtime дополнительно публикует на выбранной лампе
`lf3_transfer_weight` — фактический взаимодополняющий вес передачи между
десятой и временной одиннадцатой shadow-map. Это диагностический контракт:
сам по себе meta не меняет изображение. Любой лабораторный opacity-guard
обязан умножаться на transfer-weight и не может превращать входящую 11-ю
тень в полностью непрозрачную.

Для полностью отсоединённых occupancy-компонентов исследуется отдельный
light-zone cull. Закрытая дверь или сплошная перегородка может исключить
источники другого компонента до shadow-пула; открытый световой проём снова
соединяет компоненты. Лабораторный результат описан в
`docs/light_leak_distance_lab.md`. До общего контракта light-zone graph это
не является продуктовым изменением `level_e`.

Portal-aware receiver-layer вариант для открытого проёма отклонён:
два коротких Forward+ запуска завершились воспроизводимым SIGSEGV при
renderer-cleanup (`indexing did not unpair geometries from light`). Код
кандидата снят; `level_e` не менялся. Подробности и артефакты — в
`docs/light_leak_distance_lab.md`.

## Пространственное включение света областей

Пул света `level_e` не использует таймер для появления или гашения области.
Occupancy-граф остаётся обязательным грубым фильтром: источник участвует
только через цепочку реально открытых стыков. Внутри этого набора вклад
определяется текущим расстоянием игрока до интерьера `area_group`. Одинаковые
позиция, topology и состояние лампы обязаны давать одинаковую энергию
независимо от направления и скорости движения.

Полный и дальний bounce-профили смешиваются одной пространственной кривой.
Энергия, радиус и opacity тени используют согласованный вес; тень не должна
включаться раньше видимого вклада своего источника. За рабочим радиусом граф
держит дополнительное кольцо областей только для плавного ухода в ноль.
После нулевого веса источник скрывается без временного хвоста.

Расстояние напрямую до лампы без occupancy-фильтра запрещено: такой culling
снова включает свет геометрически близкой, но отделённой стеной области.
Слитая `area_group` считается одним помещением; пока игрок находится в любой
её части, вся группа сохраняет полный профиль.

## Пространственная передача теней в подвижном коридоре

Локальный пул `infinite_e` использует тот же бюджет LF3:
`10 + временная 11-я`. Десятая и одиннадцатая лампы получают
взаимодополняющие веса от текущего разрыва ranking-distance, а opacity каждой
тени дополнительно затухает по текущему расстоянию. Таймер, направление
движения и сохранённый progress не участвуют. Одиннадцатая shadow-map
разрешена только в зоне передачи и заранее входит с почти нулевой opacity,
чтобы дальний STOP-знак не получал скачок при смене caster.

Машинный контроль `2026-07-27`: spatial-validator `level_e` прошёл 16
координат в прямом и обратном порядке без расхождений состояния; 30 повторов
на неподвижной позиции дали нулевое изменение. Motion-runner `infinite_e`
прошёл 100 м и 10 рециклингов с `10…11` активными тенями,
`stationary energy delta = 0`, максимальный видимый energy delta
`2.61e-8`. Ручной проход подтвердил плавную тень STOP-знака и симметричное
пространственное включение света трёх залов без временного хвоста.

### LF3-11R — приоритет видимого receiver

Эксперимент `LF3-11R` устраняет визуально обратное направление предметных
теней в многоламповом зале, не меняя световую энергию и бюджет `10 + временная
11-я`. Базовый `LF3-11F` сохраняется как A/B-checkpoint. Причина артефакта:
лампа, ближайшая к игроку или важная для окклюзии, могла получить shadow-slot,
а ближайшая к видимому объекту — только освещать его без тени.

Ranking `11R` сохраняет player-distance и occupancy-risk, но добавляет
receiver-affinity. Видимые receiver-пробы строятся от активной камеры вперёд и
по краям кадра. Лампа получает affinity только если receiver лежит в её range и
сегмент `lamp→receiver` не пересекает occupancy; источник за стеной этим
приоритетом пользоваться не может. Поэтому защита от пробоя остаётся
обязательной, а среди безопасных кандидатов выше поднимается лампа, реально
ближайшая к видимой поверхности. Формула не хранит таймер или историю:
одинаковые камера и координаты дают одинаковый ranking, а граница 10/11
использует прежний пространственный crossfade.

Первый допуск выполняется box-ботом в главном зале. Он сравнивает `LF3-11F` и
`LF3-11R` на одинаковой фиксированной камере при подходе/отходе, сохраняет
контактные листы и для каждого кадра пишет ближайший достигающий коробок
источник, ближайший активный shadow-source и их направленное совпадение.
Обязательные ограничения: не более 11 теней, отсутствие роста дальнего
unshadowed leak-risk, одинаковое поведение на одинаковых координатах и
Vulkan-прогон 900 кадров без device loss. До машинного и ручного допуска
`11R` считается тестовым профилем, а не заменой принятого `11F`.

Два прогона `2026-07-22 23-50-22/23-53-50` не дали допуска. На выбранной
траектории коробок дефект не воспроизвёлся: уже `11F` держал ближайшую к
коробкам лампу с тенью во всех `81/81` кадрах подхода и отхода, поэтому `11R`
не мог доказать исправление исходного наблюдения. Лимит остался 11, device loss
нет. После устранения повторных occupancy-трассировок второй stress показал
`11F/11R = 26.65/28.92 ms`; mean unshadowed leak-risk
`1.858/1.904`, максимум одинаковый `2.979`. Из-за лишней цены и небольшого
роста среднего риска продуктовый default остаётся `LF3-11F`. Код `11R` и его
метрики сохраняются только для повторного A/B на точном ракурсе, где обратное
направление тени действительно видно.

### LF3-11A — безопасный угловой fade

Следующий эксперимент не меняет ranking принятого `11F` на receiver-first.
Вместо этого он освобождает дальние shadow-slot вне полезного обзора. До
`6 м` от игрока тень сохраняется при любом направлении камеры. Источник с
ненулевым occupancy-risk также всегда сохраняет полный угловой вес: отключать
его тень означало бы вернуть пробой при сохранённом свете.

Для остальных источников используется только пространственная формула. Полный
вес действует внутри горизонтального half-FOV камеры плюс запас `25°`, затем
плавно уходит в ноль на следующих `45°`. Если лампа физически достигает
видимой receiver-пробы без пересечения occupancy, её receiver-affinity может
поднять угловой вес. Итоговая opacity равна прежнему distance-fade, умноженному
на angular-weight; таймера и истории нет. Кандидат с нулевым весом не занимает
границу 10/11, частичный вес участвует в прежнем crossfade.

Профиль называется `LF3-11A` и до допуска остаётся A/B-режимом, продуктовый
default — `LF3-11F`. Box-smoothness бот дополнительно вращает фиксированную
камеру по одинаковой дуге в обоих направлениях и сохраняет последовательности
`rotation_cw/ccw`. Приёмка: одинаковое состояние при одинаковом угле, отсутствие
резкого step-пика на боковой границе, отсутствие роста leak-risk, максимум 11
теней, Vulkan без device loss и отсутствие регрессии среднего frame time.

Три воспроизводимых прогона `2026-07-23 00-14-46/00-18-36/00-22-25`
подтвердили одинаковые shadow-signature при CW/CCW (`0` несовпадений), лимит
`11` и отсутствие device loss. В повороте `11A` снизил mean leak-risk
`1.222 → 1.136`, максимум `1.806 → 1.728`; в stress — mean
`1.858 → 1.803`, максимум `2.979 → 2.259`. Освободившийся дальний безопасный
слот в плотном зале занял более рискованный источник, поэтому число активных
теней почти не уменьшилось. Плавность подхода/отхода сохранилась, но во всех
трёх stress-прогонах `11A` был тяжелее `11F`; последний замер
`25.13/30.05 ms`. Поэтому автоматического допуска в default нет. Для ручной
оценки уровень запускается с `--lf3-angular-shadow-test`; без флага стартует
принятый `LF3-11F`.

### LF3-11G — guardian/view pool

Следующий кандидат сохраняет удачную часть `11A`, но исключает дорогой
receiver-affinity из покадрового ranking. Один общий бюджет `10 + переходная
11-я` делится не жёсткой квотой, а приоритетом:

- **guardian** — источник с occupancy-risk для локальной либо дальней видимой
  границы; его angular-weight всегда `1` независимо от камеры;
- **near** — источник не дальше `6 м`; его тень также сохраняется со всех
  направлений;
- **view** — остальные безопасные источники; полный вес действует в FOV с
  запасом `25°` и затухает в следующие `45°`.

Угловой вес `view` считается дешёвым dot-product без `acos` и без
receiver-affinity. Distance opacity и текущие camera-receiver вычисляются
каждый кадр. Кэшируется только неизменный топологический ответ
`lamp → receiver occupancy-cell`: пересекает ли сегмент стену. Дистанционный
reach затем считается по текущей точке receiver. Кэш не содержит времени,
направления движения или крупного пространственного bucket, поэтому одна
позиция и один угол дают одинаковый результат, а переход остаётся в
существующей границе `10/11`. При изменении occupancy кэш обязан очищаться.

Первая версия с кэшем guardian-карты по `0.5 CELL/5°` отклонена maze-прогоном
`2026-07-23 00-54-03`: при хорошем результате в зале она дала
`mean leak-risk 0.00835 → 0.00965`, `max 0.1139 → 0.2765` и пропустила одну
защищённую лампу в `maze_north_cross`. Крупные position/angle buckets больше
не использовать для определения guardian.

`LF3-11G` — только A/B-кандидат; default остаётся `LF3-11F`. Допуск требует
двух тестов на одном фиксированном сиде: box/rotation в зале и четыре
фиксированных ракурса плюс 900-кадровый поперечный маршрут в maze. Проверяются
leak-risk, направленная симметрия, step-пики, frame time, максимум 11 теней и
Vulkan device loss. Ручной запуск кандидата — `--lf3-guardian-shadow-test`.

Topology-cache прошёл оба машинных допуска. Зал
`2026-07-23 01-11-23`: `11F/11G mean frame = 18.398/16.819 ms`, max
`32.377/25.331 ms`; mean leak-risk `1.858/1.809`, max `2.979/2.563`.
Peak step подхода `0.000282/0.000267`, отхода `0.000263/0.000264`; CW/CCW дали
`0` несовпадений shadow-signature. Maze `2026-07-23 01-02-01`: динамический
mean/max leak-risk совпал точно (`0.008351/0.113906`), frame time практически
равен (`14.991/15.010 ms`), а статический `maze_south_wide` улучшился с
`0.072943` до `0` при остальных ракурсах без регресса. Лимит 11 соблюдён,
device loss не было. Профиль готов к ручной визуальной оценке, но до неё
продуктовый default остаётся `LF3-11F`.

Для ручного A/B в обычном `level_e` клавиша `0` атомарно переключает
`LF3-11F ↔ LF3-11G`. Переключение не затрагивает энергию, материалы, ambient,
model-only fill и звук; текущий профиль показывается в HUD. Новый запуск без
аргументов всегда начинается в продуктовом `LF3-11F`.

### LF3-S — лаборатория стабильности мягких теней

Наблюдаемое в большом зале дрожание нельзя заранее считать только сменой
shadow-slot. Forward+ шейдер Godot вращает выборку мягкой positional shadow по
`taa_frame_count`; при выключенном TAA мягкая omni-тень способна менять
пиксельный рисунок даже при неизменных источниках, opacity, камере и геометрии.
Поэтому следующий эксперимент изолирован и не меняет продуктовый `LF3-11F`.

Лаборатория сравнивает:

- штатные `LF3-11F` и `LF3-11G`;
- замороженный после прогрева набор shadow-caster с неизменной opacity;
- несколько значений blur и quality positional shadow;
- TAA `OFF/ON` при той же геометрии, энергии, range, ambient и раскладке.

Обязательные измерения: покадровый RGB MAE неподвижной камеры, симметричный
CW/CCW-поворот, RGB/luma относительно штатного кадра, occupancy leak-risk,
число активных теней и отдельный Vulkan stress по каждому варианту. Заморозка
пула является только диагностикой: если игрок покидает проверенную позицию, она
может потерять защиту другой перегородки и не может стать продуктовым режимом.
Запекание допустимо оценивать только как статический слой контактного
затемнения; оно не заменяет occupancy-защиту процедурных и стримящихся областей.

Серия `2026-07-27 00-58-36…01-26-10` разделила причины:

- полная заморозка выбранных shadow-caster не уменьшила расхождение CW/CCW;
  значит, allocator не является главным источником текущего дрожания;
- TAA увеличил неподвижный межкадровый MAE примерно с `0.000006–0.000007`
  до `0.00038–0.00039` и ухудшил поворот; вариант отклонён;
- hard-контроль `blur=1.0` почти убрал расхождение, но слишком сильно меняет
  характер тени;
- high-quality positional filter при `blur=2.25` оказался и тяжелее, и менее
  стабильным; вариант отклонён;
- atlas `4096→8192` сильно уменьшил расхождение, но требует в четыре раза
  больше площади shadow-atlas, изменяет изображение и повышает frame time;
  при истории device loss это не продуктовый путь;
- устойчивый компромисс — topology-cache `LF3-11G`, TAA `OFF`, штатные
  quality/atlas и `blur=2.125`.

Три повторных hall-прогона кандидата дали максимум направленного RGB MAE
`0.001558…0.001560` против `0.004417…0.004419` у `LF3-11F/2.75`, то есть
снижение примерно на `65%`. Luma выросла менее чем на `0.9%`; RGB MAE к
штатному кадру около `0.001745`. Во всех прогонах максимум остался `11`,
device loss не было.

Два maze-прогона с прямым и обратным порядком подтвердили одинаковый с `11F`
динамический leak-risk (`mean=0.0083514`, `max=0.1139063`) и нулевой статический
leak-risk во всех четырёх ракурсах кандидата. `maze_south_wide` улучшился
`0.072943→0`. Порядок профилей менял относительный frame time из-за нагрева:
кандидат вторым был на `3%` тяжелее, первым — на `10%` быстрее; устойчивой
регрессии не подтверждено. Кандидат готов к ручной визуальной оценке, но
продуктовый default остаётся `LF3-11F/2.75` до решения пользователя.

Потребитель передаёт модулю только свою occupancy-функцию и, при наличии,
активную камеру. Occupancy-функция отвечает на вопрос, блокирует ли клетка
световой сегмент; координаты клетки локальны владельцу модуля. Все параметры
теней, построение receiver-проб, оценка риска и передача слота 10/11 принадлежат
`lighting_module.gd` и не копируются в новые уровни. Топологические механики
эталонных лабораторий — например direct-пул и дистанционное исчезновение света
бесконечного коридора — остаются локальными и не считаются частью LF3-11F.

Продуктовый фоновый звук `level_e` также перенесён из `infinite_e`: натуральный
зацикленный `fluorescent_lamp_hum.wav` с плотностной дистанционной громкостью и
`fluorescent_lamp_flick.wav` на фактических спадах яркости мерцающей лампы.
Предыдущий синтезированный гул/треск сохраняется только как тестовый профиль
`--level-e-reference-audio`; в обычной игре переключателя нет.

Финальная проверка после смены defaults: `2026-07-19 02-35-33`, Vulkan
завершился штатно; `REFERENCE/10J/11F = 14.179/14.049/14.053 ms`, у `11F`
активны 11 теней все 900 stress-кадров. Валидатор подтвердил старт в `11F`,
атомарный возврат Reference для теста и переключение `FINAL WAV ↔ reference`
без потери обоих профилей.

## Model-only fill — лабораторный слой

Следующий изолированный эксперимент не меняет `LF3-11F`: импортные props
получают дополнительный visual layer, а управляемые `OmniLight3D` без теней
видят только этот слой. Основной world-layer у моделей сохраняется, поэтому
штатный свет и отбрасываемые тени работают как раньше. Архитектурные меши,
пол, стены, потолок и плинтус в model-layer не входят.

Первый общий допуск `level_e`: одна система регистрирует кластер коробок
большого зала и модели табличек у провала; для каждого пространственного
кластера строится локальный fill с общей энергией `0.05`. `4` включает/
выключает всю систему, `1/2` меняют единый параметр энергии. Система остаётся
экспериментальным A/B-харнессом для будущих импортных props, а не обязательным
светом всех моделей. Новую модель можно временно зарегистрировать receiver'ом
только для парной проверки `OFF/ON`; после теста отдельно решается, оставлять ли
её в профиле. Для каждого нового receiver обязательны проверки бокового света,
формы материала, отсутствия самосвечения и неизменности архитектуры и
отбрасываемой тени. Переключатель `4` и регулировка `1/2` сохраняются до
завершения этих тестов.

Автоконтроль `2026-07-19 03-18-02/03-18-59`: зарегистрировано 5 receivers
(3 коробки + 2 предупреждающие таблички), создано 3 локальных источника с
`cull_mask=MODEL_FILL`, `shadow_enabled=false`. Для коробок ROI luma
`0.19152→0.19231` (`+0.41%`), `RGB MAE=0.000902`: изменение заметно на форме,
но не осветляет окружение. Vulkan stress прошёл 900 кадров с 11 тенями,
`mean=14.244 ms`, `max=28.822 ms`; среднее остаётся внутри ранее измеренного
разброса. Таблички требуют ручного A/B клавишей `4`.

> В `level_e` отдельно испытывается профиль окклюзии LF3-8O: клавиша `8`
> переключает неизменённый `REFERENCE` и стабильный пул до 10 теней
> (`max opacity=1.0`, `blur=2.75`, исходные bias). Этот профиль реализуется только
> в производном `level_e.gd`; правила и параметры базы ниже не переписываются,
> пока maze-тест не пройден.
> Актуальный LF3 использует максимум 10 теней без состояния передачи.
> Distance-opacity: full до `6 м`, `1-smoothstep(6,14,d)` до `14 м`, затем off.
> Для десятого слота добавлен симметричный вес
> `smoothstep(0,2,d11-d10)`, чтобы смена 10/11 происходила при нулевой opacity.
> При равной позиции подход и отход обязаны дать одинаковую тень.
> Автотест от `2026-07-18 01-46-04` подтвердил 0 расхождений состояния на 21
> паре одинаковых координат; визуальный максимум направленной разницы у коробок
> снизился с `RGB MAE=0.00213` до `0.000682`.
> Вариант с двумя дополнительными тенями отклонён после
> `VK_ERROR_DEVICE_LOST` и не должен возвращаться. Fade отвечает только за
> плавность: дальний пробой устраняется отдельно — заменой незащищённых Omni
> на occupancy-ограниченный вклад, а не дальнейшей настройкой opacity.

> Эксперимент после fixed-camera A/B: 10 теней остаются штатным набором, а
> одиннадцатая разрешена только внутри пространственного crossfade границы
> 10/11. Ближняя и дальняя лампы получают взаимодополняющие веса от разницы
> расстояний; в точке равенства обе имеют вес `0.5`. Максимум 11 действует
> лишь во время передачи. Вариант допускается только после A/B плавности,
> leak-контроля и Vulkan-стресса; это не возврат отклонённого постоянного пула 12.
> Автоконтроль `2026-07-18 22-35-41`: пик fixed-camera снизился
> `0.00037957 → 0.00021379`, направления совпали; 900/900 стресс-кадров реально
> использовали 11 теней (`mean=16.41 ms`, `max=23.69 ms`) без Vulkan-сбоя.
> Профиль оставлен активным экспериментом до ручной оценки плавности и засвета.
> Ручная оценка: тени практически достигли нужной плавности, но на длинной
> дистанции вернулся световой пробой. Поэтому профиль `LF3-11X` зафиксирован
> только как промежуточный checkpoint плавности, не как финальный свет.
> Приоритет выше плавности: восстановить дальнюю окклюзию без потери текущего
> поведения теней. До этого запрещено назначать `LF3-11X` универсальным
> профилем лабиринта или продолжать косметическую доводку fade.

> Следующий отдельный эксперимент — `LF3-11P`, occupancy-aware приоритет
> shadow-слотов. Базовый `LF3-11X` сохраняется без изменений для отката.
> В `level_e`: `8` переключает `REFERENCE ↔ LF3`, `7` внутри LF3 выбирает
> `11X` (только расстояние) или `11P` (приоритет риска пробоя).
> `11P` проверяет лучи от лампы к набору мировых проб вокруг игрока; пересечение
> `K_WALL/K_PARTITION` повышает приоритет лампы весом, зависящим от расстояния
> до проб. Лимит и crossfade остаются `10 + временная 11-я`.
> На первом этапе импортные 3D-объекты получают обычный приоритет по расстоянию;
> отдельный receiver-score по их AABB добавляется только после допуска стен.
> Автопрогон `LF3-11P` `2026-07-19 00-13-59`: в четырёх maze-ракурсах
> occupancy-риск определил 5/6/8/5 активных caster; motion 900 кадров прошёл
> без Vulkan-сбоя (`mean=16.404 ms`, `max=20.67 ms`). Fixed-camera
> `00-14-45`: направления совпали, но пик вырос относительно `11X`
> `0.00021379 → 0.00026176`. `11P` оставлен активным только потому, что
> дальняя окклюзия приоритетнее этой небольшой потери плавности; ручной leak-
> контроль обязателен.

> Для ручного поиска дальнего засвета клавиша `0` сравнивает текущий выбранный
> профиль (`LF3-11P` либо `11X`) с историческим checkpoint `LF3-10J`.
> `10J` — максимум 10 теней, distance-ranking без occupancy-priority и без
> временной 11-й; десятый слот затухает к нулю у границы 10/11. Это тот вариант,
> где направленная симметрия уже была исправлена, но визуальный shadow-pop ещё
> оставался. Переключение `0` не меняет REFERENCE, геометрию и световые энергии.

> Тройной A/B `2026-07-19 01-38-10/01-41-36`:
> `11P` плавнее `10J` на 31%, средний FPS статистически одинаков, но worst-frame
> `11P` выше (`26.97 ms`). Расчётный средний риск пробоя
> `REFERENCE/10J/11P = 0.28324/0.02468/0.00635`, что подтверждает снижение, но
> не устранение засвета. Локальные пробы дали ложный ноль на статических maze-
> кадрах при сохраняющемся ручном дальнем засвете. Поэтому `11P` не допущен:
> следующий receiver-score должен учитывать дальние видимые поверхности во
> frustum, а не только точки вокруг игрока.

> Зафиксированные checkpoints не изменять: `LF3-10J` (max-10, заметный pop)
> и `LF3-11P` (10+1, локальные occupancy-пробы). Новый эксперимент —
> `LF3-11F`: тот же профиль теней `11P`, но receiver-набор дополняется первыми
> видимыми occupancy-стенами/перегородками вдоль веера лучей камеры до `20 м`.
> Эти дальние frustum-receiver участвуют только в ranking shadow-слотов и не
> меняют энергию/радиус ламп. После первого теста уточнено: одной смены ranking
> недостаточно, потому что старый shadow-opacity обнулялся на `14 м`.
> Только caster, реально связанный с дальним frustum-receiver, использует
> плавный shadow fade `6…20 м`; локальные caster и checkpoints сохраняют
> `6…14 м`. Ручное управление упрощено: `8` переключает
> `REFERENCE ↔ выбранный LF3`, `0` — `LF3-10J ↔ LF3-11F`. Клавиша `7` больше
> не участвует в основном ручном A/B; `11P` остаётся программным checkpoint.
> Контроль `2026-07-19 01-57-59/01-59-56` подтвердил назначение `11F`.
> В динамическом прогоне его средний unshadowed-risk равен `1.271` против
> `2.042` у `10J` и `2.803` у REFERENCE; fixed-camera peak `0.0002233` против
> `0.0003796` у `10J`. В четырёх статических maze-ракурсах `11F` убрал
> незакрытые caster в двух проблемных видах (`1→0` и `2→1`), в одном оставил
> тот же слабый остаток. Цена — средний кадр `14.90 ms` против `13.80 ms` у
> `10J` в одинаковом shadow-стрессе (около 8%). Поэтому `11F` зафиксирован как
> активный дальний эксперимент, а не как финальный универсальный профиль;
> визуальный проход разных maze-вариаций остаётся решающим.
> Ручной визуальный проход `2026-07-19` признал `11F` лучшим из текущих
> вариантов. После одного пользовательского `VK_ERROR_DEVICE_LOST` выполнена
> серия стабильности: 5 последовательных fixed-camera/stress запусков
> (`02-14-04…02-20-53`) и 3 maze/motion запуска (`02-23-12…02-24-32`), все
> завершились штатно. В stress это 4500 кадров с постоянно активными 11 тенями;
> воспроизведённых Vulkan-сбоев `0/8` запусков. Причинная связь единичного
> ручного сбоя с `11F` пока не подтверждена и не опровергнута.
> Средние stress frame time по пяти запускам:
> `REFERENCE/10J/11F = 14.292/14.196/14.236 ms`
> (примерно `70.0/70.4/70.2 FPS`). Разница среднего менее 0.7% и находится в
> шуме; редкие пики остаются: worst `21.86/33.37/31.35 ms`.

> Параллельный эксперимент и его A/B-контракт описаны в
> `docs/lighting_field.md`. Скалярный LF v1 с light layers и портальными
> SpotLight признан неверным направлением и не переносится в игровые уровни.
> LF v2 строится reference-first как направленное освещение из occupancy.
> До его полного визуального и производительного допуска правила ниже
> остаются действующей системой `LEGACY`.

## Scope

Rules for ceiling light panels and runtime light sources.

## Канонические профили источника

Независимые AreaSpec-превью, для которых требуется визуальное совпадение с
`level_e`, используют `source_family=level_e_area`. Это не только численный
профиль `wide`: модуль создаёт тот же активный `AreaLight3D`, потолочный
bounce-Omni с тем же дистанционным пулом теней и скрытый legacy-Omni для
fallback. Замена этой семьи одиночным wide-Omni не считается совпадением с
`level_e`.

`lighting_module.gd` предоставляет именованный широкий профиль `wide` с
параметрами штатных источников пустых пространств `infinite_e`:
`LAMP_ENERGY`, `LAMP_RANGE` и `LAMP_ATTEN`. Он даёт связное перекрытие света
в пустом зале и не заменяется tuned/tight-профилем без явного локального
решения.

Профиль `tight` имеет уменьшенный радиус и более быстрое затухание. Он
применяется только там, где явно нужны изолированные световые пятна, например
в отдельных колонных залах. Сам факт, что пространство является залом, не
является основанием выбирать `tight`.

Лаборатория `triple_gateway_test` использует `wide` для всех источников
переносимого пустого зала, включая центральный источник над визуальным
ориентиром. Количество и раскладка панелей остаются отдельным локальным
решением лаборатории.

## Base Units

- 1 panel = 1.25 m.
- A standard ceiling light panel occupies 1x1 panel cell.
- Some area types may use double panels: 2 joined light panels in one local
  light placement cell.

## Grid Alignment (mandatory, no implicit exceptions)

Every ceiling fixture MUST sit on the canonical panel/occupancy grid of its
owning area or chunk. The X/Z position of a 1x1 fixture is always a cell center
(local `x + 0.5`, `z + 0.5`, transformed with the area); its runtime light
source inherits the same X/Z and may differ only vertically. Do not place a
fixture at a raw geometric coordinate, cell boundary, texture-space estimate,
or arbitrary meter offset. This rule also applies to hand-authored, story,
flickering, corridor, niche, and single-room lights. A template may choose a
different GRID CELL, but it may not create an off-grid fixture unless the user
explicitly requests an exception for that exact fixture.

If an instruction says **"in the center of the room/space"**, use this
selection algorithm:

1. Calculate the geometric center only as a target point; do not place the
   fixture there yet.
2. Enumerate valid ceiling-grid cell centers inside that room/space.
3. Discard cells forbidden by occupancy, clearance, or fixture-spacing rules.
4. Choose the remaining cell center with the smallest squared X/Z distance to
   the target point. Thus, if the geometric center falls between ceiling
   tiles, the fixture goes to the nearest tile center.
5. For an exact distance tie, prefer the smaller local Z cell index, then the
   smaller local X cell index, unless that template explicitly names another
   one of the tied GRID CELLS. This makes the result deterministic.

If the nearest cell is blocked, continue in the same distance order until the
nearest legal grid cell is found; never solve a blockage by nudging the fixture
off-grid. Multi-panel fixtures must likewise be unions of whole adjacent grid
cells and remain anchored to their cell centers.

Для полного пакета стандартной области `15×15` применяется сетка
`lighting_module.STANDARD_HALL_STRIDE_MULTIPLIER`: индексы панелей вычисляет
сам световой модуль. Спецификация комнаты не копирует шаг, отступ или численные
параметры источников.

## Placement Order

Light placement happens after architectural occupancy is known.

First build occupancy for:

- outer walls;
- shared walls;
- passages;
- columns;
- partitions;
- pits;
- other obstacles.

Then place lights only in valid free cells.

## Clearance Rules

Do not place ceiling light panels:

- under walls;
- under columns;
- under partitions;
- under pits or blocked ceiling cells;
- in cells directly adjacent to walls, columns, or partitions.

Obstacle clearance has priority over perfect light rhythm.

Single-panel fixtures (1x1 panel) should also keep spacing from other
single-panel fixtures: keep at least 2 empty grid cells around each panel
(including diagonals), so two 1x1 panels must not be placed in the same
5x5-cell neighborhood. This spacing rule does not apply to explicitly
designed multi-panel fixtures, such as the 1x2 double panels in `branch`, or
to a hand-authored local exception documented by that template.

## Area-Specific Light Rules

Each area may define its own light pattern.

Current examples:

- Base rooms: regular grid by local area rule.
- Branch area: double light panels, each made from two joined light panels.
- Areas with dense partitions: skip lights near partitions and place only in
  remaining legal ceiling cells.
- Maze-style areas (`maze_wilson`): do NOT reuse the default clearance check
  (see next section) — place one light per logical maze cell, at the
  in-bounds integer cell closest to that cell's center that passes direct
  occupancy and existing-light clearance; skip the light entirely if none of
  that cell's interior qualifies.

## Maze-Style Areas: Clearance Check Must Be Direct, Not the Blanket Line-Block

The generic clearance helper (`_light_blocked` in code) marks an ENTIRE
partition line's cell range as blocked, regardless of whether a given spot on
that line is an actual wall or an opening. That is a reasonable shortcut for
templates where a partition line is almost entirely solid with a couple of
narrow door cuts (office, room3): the line reads as "wall" nearly everywhere
anyway. It breaks down for maze-style areas, where a line is often MORE open
than solid (spanning-tree + braid cuts many gaps into it) — the blanket check
then blocks nearly every candidate cell in the whole area, because partition
lines sit only 2-3 panels apart and the blanket block extends across their
full length either way.

Rule: for any area whose partitions are mostly-open lines rather than
mostly-solid walls, place lights using a DIRECT occupancy check (does this
specific cell/its neighbors actually carry `K_PARTITION`/`K_WALL`/`K_COLUMN`?)
instead of the blanket per-line flag. The direct check still has to keep the
global spacing rule: the candidate cell and its 8 neighbors must be free of
both geometry blockers and already placed ceiling panels.

### Occupancy discretization gotcha (narrow but real)

The shared occupancy stamp (`_stamp_partition_occupancy`) decides "is this
whole-panel cell inside an opening?" by comparing the distance from the
cell's center to the opening's center against half the opening's width. When
an opening's width equals the grid step exactly (true for full-cell-width
maze openings, not true for calibrated door openings that are much narrower
than their host wall), some cell centers land EXACTLY on the opening boundary.
A strict `<` comparison there misclassifies that cell as wall in the
occupancy grid — lighting/map only, the actual 3D wall geometry is
unaffected — which can silently zero out every light candidate in an area.
Fixed with `<=` plus a small epsilon; keep this in mind for any future
template whose opening width equals its own grid step.

## Runtime Light Sources

The visible ceiling panel mesh and actual light source are related but not the
same thing.

### AreaLight3D experiment (default after engine update)

After updating Godot to a version with `AreaLight3D`, rectangular light
surfaces should use it as the default runtime source where possible:

- ceiling light panels;
- double branch panels;
- flickering rectangular panels;
- EXIT/sign light plates only after visual validation.

The old omni/spot setup must remain available as a runtime fallback on key
**9**. Implementation rule: create the legacy source and, when `AreaLight3D`
exists in `ClassDB`, also create the rectangular source. The active-light pool
then enables only one family at a time:

- `AreaLight3D` mode ON: rectangular sources are active;
- `AreaLight3D` mode OFF (`9`): old `OmniLight3D`/special sources are active.

On Android, do not test `AreaLight3D` under the default Mobile renderer: it
uses much lower dynamic-light limits per mesh and the project merges large
floor/wall/ceiling surfaces into shared meshes. For the Android AreaLight test
build, force the mobile rendering method to `forward_plus` and keep
`AreaLight3D` enabled, but start from an aggressive performance profile:
panel `area_range` OFF, post-processing OFF, bounce-fill shadows OFF, and only
the player's current area group lit. If FPS recovers, re-enable quality one
feature at a time. If performance or device support still fails, switch Android
back to the old `OmniLight3D` family as the runtime fallback.

Проект поддерживает только Godot 4.7 stable: совместимость этого кода с 4.6 и
более ранними версиями не требуется. Текущее динамическое создание
`AreaLight3D` через `ClassDB` можно сохранять как деталь реализации, но оно не
должно использоваться как причина ограничивать возможности Godot 4.7.

Area lights are more expensive than omni lights. Keep shadows off by default
for the full-level pass; enable them later only for selected hero fixtures if
FPS allows it.

Лабораторный occupancy-suppression не заменяет источник и не увеличивает
shadow-budget: после штатного выбора LF3 он может плавно уменьшать энергию
только у незащищённого bounce-источника, если его луч к receiver-пробам
пересекает закрытую occupancy-ячейку. Открытый проём считается открытым путём.
Такой кандидат обязан проверяться отдельно на движении в светлой и тёмной
частях; зависимость от направления камеры запрещена.

Принятый лабораторный вес:
`energy = base × (1 - blocked_weight × (1 - shadow_coverage))`, где
`shadow_coverage = clamp(shadow_opacity, 0, 1)`. Для blocked-источника
topology-guard поднимает opacity с учётом штатного `transfer_weight`.
Это комплементарный crossfade: смена штатного LF3 caster не выключает Omni
скачком, а передаёт вклад одновременно с opacity тени.

Повторный ручной тест показал, что даже комплементарный вес заметен при
движении вдоль стены. Следующий лабораторный профиль `zone_static_11`
фиксирует один topology-набор из 11 Omni для всей зоны. Дополнительные Omni
не меняют тип или роль; их энергия зависит только от непрерывного расстояния
до границы светлой/тёмной зоны.

Универсальная версия не имеет права знать ось, номер строки перегородки или
конкретный проём. `light_zone_profile_module.gd` получает только occupancy,
границы сетки и клетки источников:

1. клетки `passage` временно исключаются из flood-fill и группируются в
   порталы;
2. оставшиеся проходимые клетки образуют световые зоны;
3. для всего связанного topology-кластера выбирается один постоянный набор
   `10+1` Omni, ранжированный по близости к порталам и соседним зонам;
4. для каждой зоны строится неизменный energy/opacity-профиль: собственные
   источники и выбранные `10+1` остаются активны, остальные межзонные bounce
   подавляются;
5. около портала соседние профили смешиваются по мировой позиции и нормали
   портала. Камера, кадр, направление движения и время в расчёт не входят.

Один topology-кластер всегда использует один caster-набор, поэтому portal
blend не создаёт временный второй набор теней и не превышает бюджет 11.

### Отклонённый перенос light-zone профиля в level_e

Универсальный профиль остаётся принятым для изолированной составной области,
но отклонён как общий runtime всего `level_e`. Ручная клавиша `V` и стартовый
аргумент кандидата удалены: продуктовый уровень всегда использует
`LF3-11F`. Data-only адаптер и маршрутный runner могут оставаться
диагностическим материалом, но не включаются игроком.

Адаптер `level_e` заранее строит план для каждого anchor-`area_group`
(одиночная область образует группу из самой себя). В план входят сам anchor
и непосредственно соединённые с ним occupancy-проходом соседние группы:
этого достаточно для межзонного подавления в видимом стыке, но caster-набор
не размазывается по всему связанному лабиринту. Адаптер переводит только
канонические `K_FLOOR` и `K_PASSAGE` в публичные виды `floor/passage`;
стены, перегородки, колонны, ниши и провалы непроходимы. Стыки между членами
одного `area_group` считаются продолжением пола, а не световым порталом:
четыре части большого хаба поэтому сохраняют один интерьер и один локальный
набор теней. Обрезанный границей кластера passage только с одной соседней
зоной не участвует в caster-ranking.

Все anchor-планы строятся заранее и не перестраиваются покадрово: новая сборка
разрешена только после изменения occupancy-топологии или окончательного
списка bounce-источников. Стриминг мешей не меняет логическую occupancy и
потому не инвалидирует планы. Runtime выбирает заранее готовый план текущего
anchor-`area_group`; дальние группы продолжают использовать уже принятый
пространственный pool/fade.

`ZONE-11` накладывается поверх уже рассчитанного пространственного пула:
сохраняет его visibility/range/fade, умножает итоговую bounce-energy на
зональный вес и назначает тени только постоянному caster-набору плана.
В caster-ranking участвуют только источники с каноническим
`bounce_shadow_allowed`; checker/emissive-only панели сохраняются в energy-
профиле, но не занимают один из 11 shadow-slot. Проверены anchor-focus,
portal-only и смешанный `ceil(11/2)` anchor/portal ranking. Ни один вариант не
устраняет фундаментальную ошибку: при смене anchor-плана глобальная энергия
источников меняется для всей видимой соседней области.
AreaLight-панели, эмиссия, ambient, материалы, звук, геометрия и
`infinite_e` не изменяются. При переходе во встроенный `infinite_e` профиль
`level_e` естественно приостанавливается вместе с runtime самого уровня.

Первый допуск обязан сравнить оба режима на одном сиде в большом хабе, на
линии видимости трёх залов, в maze и у перехода `level_e → infinite_e`.
Проверяются: максимум 11 теней, неизменный caster-signature при движении
внутри зоны, монотонный portal-blend, отсутствие скачка энергии, FPS и
Vulkan device loss. До ручного допуска default остаётся `LF3-11F`.

Финальный маршрутный контроль `2026-07-28 23-35-21` прошёл 35 реальных
стыков: у кандидата `max energy-step=85.0`, `max leak-risk=2.988241` против
`2.087817` у `LF3-11F`. Смешанный ranking дал те же значения, что
anchor-focus. Перенос отклонён. Расширять portal fade запрещено: это лишь
зажигает соседнюю область раньше и одновременно расширяет засвет.

Unlike legacy omni sources, ceiling `AreaLight3D` panels are the light surface
itself. Do not apply the `level_d` vertical source-drop rule to them: keep the
area light close to the visible panel underside. The source-drop rule remains
for old point/spot sources.

`AreaLight3D` is directional and does not provide the old fake ceiling bounce:
it lights downward, but the surrounding ceiling surface and upper wall band can
look flat/dark without GI. In AreaLight mode keep a tiny, short-range omni
beside each panel as a **ceiling-bounce halo**. This is not the primary light;
it is a cheap visual fill for the panel face, ceiling tile, and upper wall
gradient that the previous omni source provided accidentally.

If the ceiling still looks dead, do not rely on a decorative glow quad: it tends
to read as a muddy overlay rather than real illumination. Use a real omni
**ceiling/upper-room fill** beside the AreaLight instead. This fill is global
for all room sizes, not only big halls: it supports the ceiling, upper walls,
and partition tops so the ceiling-wall seam does not collapse into a harsh dark
line. Because it affects room geometry again, it must cast shadows; otherwise
it would reintroduce the old omni leak through partitions and walls.
Keep this fill softer than the old main omni: reduce range/energy before
raising it, and tune shadow opacity/blur/bias so partition shadows read as
soft depth, not hard black cuts across ceiling tiles. If shadows need more
separation, raise opacity first and pair it with a small blur increase: this
makes the light-shadow transition more contrasty without making the edge
harder.
For FPS, do not let every active ceiling-bounce fill cast shadows. The visual
fill may stay active for the current area and connected neighbors, but bounce
shadow casters are selected inside that active set by distance to the player,
with `shadow_opacity` fading out before the source is disabled. Do not gate
bounce shadows only by current `area_group`: when the player crosses an area
boundary, that hard switch makes border shadows visibly pop. Area/group
membership is only the coarse "can this lamp be active at all?" filter;
distance and opacity fade decide which active lamps cast shadows.

Accepted default after live testing on the target MacBook Pro 2019:
`AREA_LIGHT_BOUNCE_SHADOW_CASTERS = 10`,
`AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST = 5.0`,
`AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST = 11.0`. Measured result in `level_d`:
`maze_wilson_x2` holds about 55-60 fps, and the big hub hall holds about
40-50 fps. This is a good baseline; do not retune unless a new scene or
device profile shows a clear regression.

In the merged central hub, the seam/cross panels are fill-only for shadows:
they may still emit visible panel light and bounce fill, but their bounce
shadow maps stay disabled. Keep shadows on perimeter/near-wall panels first,
because those shadows sell the room depth more clearly and cost less in the
most overdraw-heavy central view.
For multi-area templates that read as one continuous room, shadow grouping
must follow the template, not the raw area cell. Mark every area in that shared
space with the same `area_group` value, regardless of the template type or
whether the group contains 2, 4, or more area cells. This keeps bounce shadows
from switching while crossing or looking through internal seams.
By default, rectangular ceiling panels start with their own `area_range` on the
tiny non-zero test value, while the ceiling-bounce fill stays active. This
keeps the useful ceiling fill but removes the visible wall/ceiling "beam" made
by the panel radius. Key **8** remains an A/B test: it toggles only the
rectangular ceiling panel's own `area_range` between this default tiny value
and the full tuned value. Do not use exact `0.0` here: in Godot/Vulkan it can
behave like a degenerate AreaLight and trip `fence_wait`. EXIT/sign plates are
not part of this test.

EXIT/sign plates currently stay on the calibrated legacy reflex even while
AreaLight mode is ON. A plate-local `AreaLight3D` caused motion-dependent
glints on the sign surface; keep sign materials unshaded/non-specular and
retest plate area lights later as a separate pass.

Recommended direction:

- build all visible emissive panels as geometry;
- manage actual OmniLight3D instances separately;
- keep only nearby/visible/high-priority light sources enabled;
- use area/chunk visibility and player distance/FOV for runtime culling.

### Active-light management (implemented — root cause of "light sometimes disappears")

The rule above was written before it was actually implemented: every
`OmniLight3D` created by `_spawn_lamp_source` stayed `visible = true` for the
entire level regardless of the player's position. As the level grew (macro
DFS block, more areas), total simultaneous lamp count grew with it, and the
renderer would occasionally silently skip drawing some sources for a frame —
perceived as light randomly disappearing, most noticeable in the hub (the
single most lamp-dense room, so most likely to hit a render budget edge).

Went through four iterations before landing on the correct model:

1. **Nearest-N distance budget (rejected).** Kept only the N lamps nearest
   the player `.visible = true` (same hysteresis pattern as
   `_update_shadow_pool()`). Wrong model: raw distance to the player is not
   the same thing as visibility. Symptom got WORSE in a specific way — lights
   would visibly switch on/off far away, in rooms the player was directly
   looking at, just because some other room happened to have more lamps
   physically closer.
2. **+ own-room exemption (patch, still incomplete).** Tagged every lamp with
   its home area id at spawn time (`_spawn_lamp_source` reverse-looks-up
   `_area_id` from the lamp's world position) and exempted the player's
   current area — and its merge-group, `_area_group()` (areas with the same
   `area_group` marker) — from the distance budget entirely. Fixed dropouts
   in the room you're standing in, but a second bug
   surfaced: `_area_id` is only stamped on each area's own interior
   (`_build_grid`), not on the `WALL_CELLS`-wide seam `_carve_passages` opens
   between merged areas — standing exactly in that seam made the lookup
   return `""`, dropping the whole hub back under the plain distance budget
   for that frame. Patched with `_player_area_ids()` (search a small radius
   around the player's cell for any tagged neighbor), but the underlying
   model (distance-based budget for anything not the current room) was still
   wrong for the same reason as step 1.
3. **Real line-of-sight raycast (rejected).** Cast a ray from the player's eye
   height to each candidate lamp against the level's static collision body;
   empty hit result = unobstructed = keep lit. Correct in principle (distance
   was never the right proxy, occlusion is), but a per-frame physics query
   against a moving player produced its own visible glitching — reported as
   flicker/lights toggling that looked like the check couldn't keep up with
   player movement.
4. **Area + connected-neighbor rule (current, correct model).** No physics
   query at all: always light the player's current area (+ its merge-group)
   AND every area actually CONNECTED to it by a passage — `_cells_connected()`
   inspects the `WALL_CELLS`-wide seam between two area cells directly in the
   occupancy grid (any non-`K_WALL` cell there means an opening exists),
   rather than assuming grid-adjacency implies a passage (it doesn't — ring/
   spine/spokes/macro-DFS all leave some sides closed). Deterministic, no
   per-frame physics, no chance of lagging behind a fast-moving player.
   In AreaLight mode only, areas two graph steps away may receive a deliberately
   weak, short-range bounce-fill with no shadows. This is a depth cue, not full
   room lighting: do not extend old omni lights or full panel ranges into far
   rooms by default.

### Performance: cost is in radius, not count (measured)

Profiling the big hall (Forward+, clustered) gave a clear result:

- All omni sources OFF -> 60 fps; all ON -> 40 fps.
- Hiding HALF the omnis -> no change. Light count is NOT the driver.
- Shrinking every omni's `omni_range` (x0.6) -> 55 fps. Radius IS the driver.

Reason: dense lamps with wide range heavily overlap, so many lights fall into
each cluster; per-pixel the lighting loop stays long no matter how many lamps
you delete (the rest still reach the same clusters). Emissive panels do NOT
light surfaces (no GI), so illumination comes only from omnis.

Rules that follow:

- Keep `omni_range` small (cost scales with cluster coverage / overlap).
- Do NOT compensate dark gaps by widening range - that re-introduces the cost.
  Compensate with LOW `omni_attenuation` (brighter toward the edge of the same
  small radius) and/or a small energy/ambient lift. Attenuation is free.
- Occlusion/area culling of omnis is rejected: distant areas go black and kill
  the depth-into-distance atmosphere (panels alone can't hold it).
- SDFGI is rejected: blocky/quantized GI on large open procedural spaces.

Fundamental tradeoff (accepted, not solved): contrast/depth needs pooled light
with dark gaps; killing the gaps means widening range = fps cost, or adding
lamps. The default keeps the original wide contrast look.

Default = original wide light (`LAMP_RANGE` 10 / `LAMP_ATTEN` 0.85 soft,
`LAMP_RANGE_OLD` 7 / 1.0 tight), toggled new/old by G. The rectangular
`AreaLight3D` source family is toggled against the legacy source family by
key **9**. An optional fps-tuned light (small radius) is available on key
**2** (`TUNED_*` constants). Old live fine-tune keys for range/energy/
attenuation have been removed from the runtime HUD and input path; fixed
constants are the source of truth again.

## Flickering Lamps (standard behavior)

A flickering lamp follows a scripted on/flicker pattern, not a uniform wobble.
This is the default for ANY flickering lamp unless a specific lamp overrides it.
It must inherit the same visible panel material and the same runtime light
family as a normal ceiling lamp: legacy omni in old mode, `AreaLight3D` plus
ceiling-bounce fill in Area mode. Any extra spot aimed at a sign is a local
accent, not a replacement for the standard lamp stack.
Because flickering panels use an unshaded visible material, the flicker curve
must drive both emission strength and panel albedo. Otherwise the light sources
dim while the white panel surface still reads as lit. Do not drop the visible
panel to true black or gray during flicker: keep a pale residual glow so the
fixture still reads as a weakly powered lamp, not a dark ceiling tile.

Light pattern:

- `on` segment — steady full brightness, 3 s ("dash").
- `dot` segment — flicker burst, 1 s: brightness stutters in irregular short
  steps (mostly low/dim, occasional full-brightness re-ignition spikes).
- Sequence cycles, e.g. `- .. - ... -` (on, 2 dots, on, 3 dots, ...).

Sound (tied to the same brightness curve, distance-attenuated like any lamp):

- while burning steadily (`on`) — a clean steady hum, no crackle;
- during flicker (`dot`) — both hum and crackle scale with current brightness:
  loud crackle on the re-ignition spikes ("потухла–зажглась с треском"), quiet
  when dim. Crackle appears only in the flicker phase, never during steady burn.
- Calibration: the steady-burn hum of a flickering lamp must match a single
  normal lamp's contribution to the room hum — same frequencies (60/120 Hz) and
  level. A single flickering lamp must not sound louder than a single normal
  one, nor overpower a hall full of lamps.

Reference implementation: `level_areas_c.gd` — `FLICK_PATTERN`,
`_update_pit_flicker`, `_fill_flick`.

## Область — это ВСЯ область (слияния и выемки)

Правило (зафиксировано). Если область объединена с соседями (слитые залы хаба,
общий проём во всю стену) или имеет выемку/карман (вырезанное в стене
пространство), то эти дополнительные клетки — **часть той же области**. Свет в
них гасить нельзя.

Технический нюанс: пул света (`_update_light_pool`) держит лампу включённой
только если её `area_id` попал в набор областей игрока. Но `area_id` в сетке
проставлен лишь для клеток-**интерьеров** области; карвленые стыки и клетки
выемок его не имеют (`""`), и лампа на такой клетке гаснет всегда.

Решение — общее правило в источнике света: **лампа без своего `area_id`
наследует ближайший** (тем же поиском по соседям, что и `_player_area_ids`
у игрока). Не проставлять `area_id` вручную в каждом месте.

Reference implementation: `level_d.gd` — `_spawn_lamp_source` (fallback area_id).

## `level_d`: фиксированный свет основного хаба и провала

Пока правило явно не изменено в docs, основной хаб и провал в `level_d`
сохраняют один и тот же световой облик при любой раскладке уровня.

Основной хаб:

- 4 центральных `column_hall` объединены в один 2×2 зал;
- потолочные панели ставятся по сетке `LIGHT_MARGIN`/`LIGHT_STEP`;
- в больших залах при `HALL_LIGHT_CHECKER` часть позиций полностью пропускается:
  нет видимой панели, `AreaLight3D`, bounce-fill и shadow-map; это основной
  FPS-рычаг для центрального хаба;
- центральные швы хаба досвечиваются редкими тугими источниками
  `_add_hub_seam_lights`;
- все runtime-источники света `level_d` проходят через общий хук
  `_apply_runtime_light_rules` и опущены через `LAMP_SOURCE_DROP_D`, чтобы
  сохранить лужи света на полу и снизить ощущение плоского потолочного света.
  Это глобальное правило света `level_d`, не частный случай провала. Исключение:
  источники, привязанные к EXIT-знаку, не смещаются, потому что их позиция
  калибрована относительно самой светящейся плиты.

Провал:

- обычная СЗ-угловая лампа провала убрана, потому что её роль занимает
  входная мигающая лампа;
- в комнате остаются фиксированные лампы у дальних углов и в центре;
- в кармане у входа есть отдельный тугой светильник;
- мигающая входная лампа всегда светит на WetFloorSign направленным светом.

## Пробой bounce-fill сквозь перегородки (диагноз, level_e)

Симптом: свет протекает сквозь тонкие перегородки (0.25 м) в соседние комнаты.
Источник — bounce-fill омни, а не панели: `AREA_LIGHT_SHADOWS = false` (панели
теней не бросают, но их `area_range` по умолчанию на крошечном тест-значении, так
что вбок почти не стреляют). Разносит свет по комнате именно bounce-омни
(`AREA_LIGHT_BOUNCE_RANGE = 8 м`, energy `0.36`).

Тени bounce раздаёт ПУЛ `_update_bounce_shadow_pool`: только
`AREA_LIGHT_BOUNCE_SHADOW_CASTERS = 10` ближайших ламп, с фейдом по дистанции
`FULL_DIST = 5 м` / `FADE_DIST = 11 м`. Всё, что дальше или вне 10 ближайших,
светит БЕЗ теней и течёт сквозь перегородки (которые стоят в 2–3 панелях друг от
друга). Это соответствует правилу выше: «fill … must cast shadows; otherwise it
would reintroduce the old omni leak through partitions and walls» — на практике
тени есть не у всех bounce-ламп.

Рычаги против пробоя (по возрастанию цены):
1. **Радиус bounce** (`AREA_LIGHT_BOUNCE_RANGE`) — сокращает дальность утечки.
   Живая крутилка `[`/`]` в level_e (через мету `base_bounce_range`).
2. **Больше/дальше теневых кастеров** (`CASTERS`, `FULL/FADE_DIST`) — меньше
   протечки, но дороже по fps.
3. **`AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS = 1.25`** — велик для стены 0.25 м;
   если тени есть, но течёт у основания перегородки, снижать его.

Статус: диагноз зафиксирован, подбор значений отложен (крутилки в level_e готовы
для экспериментов на прогоне).

## Notes

Light rules are editable. When a new architectural pattern is added, update
this file if it introduces a new panel type, spacing rule, or clearance rule.

## Асинхронная смена occupancy-топологии LF3

- Полный `LF3OccupancySolver.solve()` запрещён на основном потоке во время
  игрового переключения топологии. Источник света передаётся как неизменяемый
  snapshot (`bounds`, `active_rects`, `closed_segments`, `emitters`,
  `cache_key`), adapter и solver выполняются worker-потоком.
- Основной поток только принимает готовое поле, создаёт GPU-текстуру и
  атомарно перепривязывает материал. Пока новое поле не готово, действует
  предыдущее; синхронного fallback во время игры нет.
- Любая заранее известная смена — удаление постановочной комнаты, открытие
  выхода, пристыковка области-шлюза — обязана запросить подготовку до изменения
  видимой геометрии и дождаться `lf3_indirect_topology_ready(key)`.
  `cache_key` включает тип и ревизию топологии, поэтому механизм не привязан к
  прямому коридору или конкретной двери.
- Перемещение неизменной периодической топологии продолжает использовать
  дешёвый `reproject`; worker запускается только при смене содержимого поля.
- Если старая и новая топологии ещё могут быть одновременно представлены,
  commit предваряется пространственным blend их готовых полей. Вес зависит от
  расстояния до topology-anchor, а не от времени: неподвижный игрок не меняет
  свет. Для удаления постановочной комнаты blend завершается до рециклинга;
  для будущего шлюза тем же контрактом смешиваются corridor и gateway snapshot.
