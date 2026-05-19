#NoEnv
#SingleInstance Force
#InstallKeybdHook
#UseHook
SendMode Input
SetWorkingDir %A_ScriptDir%

; ============================================================
; TriPane — 多屏窗口分组管理系统
; Per-monitor dual-group window manager for Windows
; 横屏: 左/右分组 | 竖屏: 上/下分组
; ============================================================

; DPI Per-Monitor V2
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

; ============================================================
; Data structures
; ============================================================
monitors := []        ; 每屏一份 {wa, is_portrait, first_set, second_set, first_order, second_order}
window_original := {} ; 窗口原始位置快照
g_last_other_hwnd := 0 ; 上次 Alt+2 轮换到的窗口，用于跨组回退定位

; ============================================================
; Tray menu
; ============================================================
Menu, Tray, Add
Menu, Tray, Add, 显示分类状态, ShowStatus
Menu, Tray, Add, 重新加载, ReloadScript
Menu, Tray, Default, 显示分类状态
Menu, Tray, Tip, TriPane 多屏窗口分组管理器

; ============================================================
; Cleanup + auto-classify timer
; ============================================================
SetTimer, CleanupWindows, 1000

; ============================================================
; Auto-classify existing half-screen windows on startup
; ============================================================
ClassifyExistingWindows()

; ============================================================
; OSD (positioned on the correct monitor)
; ============================================================
ShowOSD(text, hwnd:="") {
    if (hwnd != "") {
        md := GetMonitorData(hwnd)
        wa := md.wa
        cx := wa.left + (wa.right - wa.left)//2
        cy := wa.top + (wa.bottom - wa.top)//2
        ToolTip, %text%, % cx, % cy - 50
    } else {
        ToolTip, %text%, A_ScreenWidth//2, A_ScreenHeight//2 - 50
    }
    SetTimer, HideOSD, -800
}

HideOSD:
    ToolTip
return

; ============================================================
; Monitor helpers
; ============================================================

IsExcluded(hwnd) {
    WinGetClass, cls, ahk_id %hwnd%
    if (cls = "Progman" || cls = "WorkerW" || cls = "Shell_TrayWnd"
     || cls = "Windows.UI.Core.CoreWindow")
        return true
    WinGet, style, Style, ahk_id %hwnd%
    if (!(style & 0x10000000))
        return true
    WinGet, exStyle, ExStyle, ahk_id %hwnd%
    if (exStyle & 0x80)  ; WS_EX_TOOLWINDOW — 无任务栏入口
        return true
    WinGetTitle, title, ahk_id %hwnd%
    if (title = "")
        return true
    DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "int*", cloaked, "uint", 4)
    if (cloaked != 0)
        return true
    if (hwnd = A_ScriptHwnd)
        return true
    return false
}

; 获取窗口所属显示器的工作区
GetMonitorWorkArea(hwnd) {
    hMon := DllCall("MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr")
    VarSetCapacity(mi, 40, 0)
    NumPut(40, mi, 0, "uint")
    DllCall("GetMonitorInfo", "ptr", hMon, "ptr", &mi)
    wa := {}
    wa.left   := NumGet(mi, 20, "int")
    wa.top    := NumGet(mi, 24, "int")
    wa.right  := NumGet(mi, 28, "int")
    wa.bottom := NumGet(mi, 32, "int")
    return wa
}

; 获取（或惰性创建）窗口所在显示器的分组数据
GetMonitorData(hwnd) {
    global monitors
    wa := GetMonitorWorkArea(hwnd)
    ; 按工作区坐标匹配已有的条目
    for idx, mon in monitors {
        if (mon.wa.left = wa.left && mon.wa.top = wa.top
         && mon.wa.right = wa.right && mon.wa.bottom = wa.bottom)
            return mon
    }
    ; 没找到 → 新建
    mon := {}
    mon.wa          := wa
    mon.is_portrait := (wa.right - wa.left) < (wa.bottom - wa.top)
    mon.first_set   := {}
    mon.second_set  := {}
    mon.first_order := []
    mon.second_order:= []
    mon.other_set   := {}
    mon.other_order := []
    monitors.Push(mon)
    return mon
}

; --- 判断窗口是否贴了半屏 ---
; 横屏: 返回 "first"(左) / "second"(右) / ""
; 竖屏: 返回 "first"(上) / "second"(下) / ""
DetectHalfGroup(hwnd) {
    mon := GetMonitorData(hwnd)
    wa := mon.wa
    monitorW := wa.right - wa.left
    monitorH := wa.bottom - wa.top

    WinGetPos, wx, wy, ww, wh, ahk_id %hwnd%

    if (mon.is_portrait) {
        ; 竖屏 → 检测上下半屏（高度约为一半）
        halfH := monitorH // 2
        halfDiff := Abs(wh - halfH)
        maxErr := (monitorH * 2) // 100
        if (maxErr < 10)
            maxErr := 10
        if (halfDiff > maxErr)
            return ""
        if (Abs(wy - wa.top) <= maxErr)
            return "first"
        if (Abs(wy - (wa.top + halfH)) <= maxErr)
            return "second"
    } else {
        ; 横屏 → 检测左右半屏（宽度约为一半，原有逻辑）
        halfW := monitorW // 2
        halfDiff := Abs(ww - halfW)
        maxErr := (monitorW * 2) // 100
        if (maxErr < 10)
            maxErr := 10
        if (halfDiff > maxErr)
            return ""
        if (Abs(wx - wa.left) <= maxErr)
            return "first"
        if (Abs(wx - (wa.left + halfW)) <= maxErr)
            return "second"
    }
    return ""
}

RemoveFromList(list, value) {
    for idx, val in list {
        if (val = value) {
            list.RemoveAt(idx)
            return
        }
    }
}

CleanList(list, set) {
    i := 1
    while (i <= list.Length()) {
        if (!WinExist("ahk_id " . list[i])) {
            set.Delete(list[i])
            list.RemoveAt(i)
        } else {
            i++
        }
    }
}

SaveOriginalIfFirst(hwnd) {
    global window_original
    if (!ObjHasKey(window_original, hwnd)) {
        WinGetPos, ox, oy, ow, oh, ahk_id %hwnd%
        window_original[hwnd] := {x: ox, y: oy, w: ow, h: oh}
    }
}

; 将窗口贴到半屏位置（横屏=左/右，竖屏=上/下）
PositionToHalf(hwnd, which, is_portrait) {
    wa := GetMonitorWorkArea(hwnd)
    fullW := wa.right - wa.left
    fullH := wa.bottom - wa.top
    WinRestore, ahk_id %hwnd%
    if (is_portrait) {
        ; 竖屏：上/下
        halfH := fullH // 2
        if (which = "first")
            WinMove, ahk_id %hwnd%, , % wa.left, % wa.top, % fullW, % halfH
        else
            WinMove, ahk_id %hwnd%, , % wa.left, % wa.top + halfH, % fullW, % halfH
    } else {
        ; 横屏：左/右
        halfW := fullW // 2
        if (which = "first")
            WinMove, ahk_id %hwnd%, , % wa.left, % wa.top, % halfW, % fullH
        else
            WinMove, ahk_id %hwnd%, , % wa.left + halfW, % wa.top, % halfW, % fullH
    }
}

GetGroupLabel(mon) {
    if (mon.is_portrait)
        return {first: "上方", second: "下方"}
    else
        return {first: "左侧", second: "右侧"}
}

; 将窗口归入当前显示屏的某个半屏组
AssignWindow(hwnd, targetWhich) {
    global monitors
    mon := GetMonitorData(hwnd)
    fs := mon.first_set
    ss := mon.second_set
    fo := mon.first_order
    so := mon.second_order

    ; 已经在目标组 → 只移动位置
    if ((targetWhich = "first" && ObjHasKey(fs, hwnd))
        || (targetWhich = "second" && ObjHasKey(ss, hwnd))) {
        PositionToHalf(hwnd, targetWhich, mon.is_portrait)
        WinActivate, ahk_id %hwnd%
        return true
    }

    SaveOriginalIfFirst(hwnd)

    ; 从对偶组移除
    if (targetWhich = "first" && ObjHasKey(ss, hwnd)) {
        ss.Delete(hwnd)
        RemoveFromList(so, hwnd)
    }
    if (targetWhich = "second" && ObjHasKey(fs, hwnd)) {
        fs.Delete(hwnd)
        RemoveFromList(fo, hwnd)
    }
    ; 从其他组移除（如果当前在其他未分类池中）
    if (ObjHasKey(mon.other_set, hwnd)) {
        mon.other_set.Delete(hwnd)
        RemoveFromList(mon.other_order, hwnd)
    }

    if (targetWhich = "first") {
        fs[hwnd] := true
        fo.Push(hwnd)
    } else {
        ss[hwnd] := true
        so.Push(hwnd)
    }
    PositionToHalf(hwnd, targetWhich, mon.is_portrait)
    WinActivate, ahk_id %hwnd%
    return true
}

; 将窗口从所在分组移除，放回"其他"
UnassignWindow(hwnd) {
    global monitors
    mon := GetMonitorData(hwnd)
    removed := false
    if (ObjHasKey(mon.first_set, hwnd)) {
        mon.first_set.Delete(hwnd)
        RemoveFromList(mon.first_order, hwnd)
        removed := true
    }
    if (ObjHasKey(mon.second_set, hwnd)) {
        mon.second_set.Delete(hwnd)
        RemoveFromList(mon.second_order, hwnd)
        removed := true
    }
    return removed
}

; 检查窗口是否已分类窗口的浮动面板/工具窗口（通过 owner 关系检测）
IsFloatingPanelOfClassified(h) {
    global monitors
    ; 获取 owner（拥有者窗口），GW_OWNER = 4
    owner := DllCall("GetWindow", "ptr", h, "uint", 4)
    if (!owner)
        return false
    ; 检查 owner 是否在任一分组的分类组中
    for mi, m in monitors {
        if (ObjHasKey(m.first_set, owner) || ObjHasKey(m.second_set, owner))
            return true
    }
    return false
}

; ============================================================
; 获取真实的"活动主窗口"：若当前焦点在工具窗口/子窗口上，
; 则向上追溯 owner 链或父窗口链，找到可操作的主窗口
; ============================================================
GetTrueActiveWindow() {
    hwnd := WinExist("A")
    if (!IsExcluded(hwnd))
        return hwnd
    ; 尝试沿着 owner 链向上追溯（GW_OWNER = 4）
    ; 工具窗口/浮动面板通常有 owner 指向主窗口
    owner := hwnd
    Loop, 10 {
        owner := DllCall("GetWindow", "ptr", owner, "uint", 4)
        if (!owner)
            break
        if (!IsExcluded(owner))
            return owner
    }
    ; owner 链没找到 → 尝试父窗口链（GW_PARENT = 2）
    parent := hwnd
    Loop, 10 {
        parent := DllCall("GetWindow", "ptr", parent, "uint", 2)
        if (!parent)
            break
        if (!IsExcluded(parent))
            return parent
    }
    ; 都找不到则返回原始 hwnd（保持原行为）
    return hwnd
}

; 收集所有未分类窗口
GetOtherWindows() {
    global monitors
    targets := []
    WinGet, allIds, List
    Loop, % allIds {
        h := allIds%A_Index%
        if (IsExcluded(h))
            continue
        isAssigned := false
        for idx, mon in monitors {
            if (ObjHasKey(mon.first_set, h) || ObjHasKey(mon.second_set, h)) {
                isAssigned := true
                break
            }
        }
        if (isAssigned)
            continue
        ; 浮动面板检测：窗口拥有者已在分类组中，则跳过
        if (IsFloatingPanelOfClassified(h))
            continue
        targets.Push(h)
    }
    return targets
}

; 收集当前屏幕的未分类窗口（按屏筛选）
GetOtherWindowsForMonitor(mon) {
    targets := []
    WinGet, allIds, List
    Loop, % allIds {
        h := allIds%A_Index%
        if (IsExcluded(h))
            continue
        ; 只取属于当前 monitor 的窗口
        wa := GetMonitorWorkArea(h)
        if (wa.left != mon.wa.left || wa.top != mon.wa.top
         || wa.right != mon.wa.right || wa.bottom != mon.wa.bottom)
            continue
        if (ObjHasKey(mon.first_set, h) || ObjHasKey(mon.second_set, h))
            continue
        ; 浮动面板检测：窗口拥有者已在分类组中，则跳过
        if (IsFloatingPanelOfClassified(h))
            continue
        targets.Push(h)
    }
    return targets
}

; 同步当前屏幕的三个 order 数组：移除失效/已分类窗口，追加新未分类窗口
SyncGroupOrder(mon) {
    global monitors
    ; first_order：移除不在 first_set 中或已关闭的窗口
    i := 1
    while (i <= mon.first_order.Length()) {
        h := mon.first_order[i]
        if (!WinExist("ahk_id " . h) || !ObjHasKey(mon.first_set, h)) {
            mon.first_set.Delete(h)
            mon.first_order.RemoveAt(i)
        } else {
            i++
        }
    }
    ; second_order：同理
    i := 1
    while (i <= mon.second_order.Length()) {
        h := mon.second_order[i]
        if (!WinExist("ahk_id " . h) || !ObjHasKey(mon.second_set, h)) {
            mon.second_set.Delete(h)
            mon.second_order.RemoveAt(i)
        } else {
            i++
        }
    }
    ; other_order：移除已归入 first/second、移出本屏或已关闭的窗口
    i := 1
    while (i <= mon.other_order.Length()) {
        h := mon.other_order[i]
        if (!WinExist("ahk_id " . h)) {
            mon.other_set.Delete(h)
            mon.other_order.RemoveAt(i)
            continue
        }
        ; 检查是否已归入任意屏幕的分类（当前屏或其他屏）
        isClassified := false
        for mi, m in monitors {
            if (ObjHasKey(m.first_set, h) || ObjHasKey(m.second_set, h)) {
                isClassified := true
                break
            }
        }
        if (isClassified) {
            mon.other_set.Delete(h)
            mon.other_order.RemoveAt(i)
            continue
        }
        wa := GetMonitorWorkArea(h)
        if (wa.left != mon.wa.left || wa.top != mon.wa.top
         || wa.right != mon.wa.right || wa.bottom != mon.wa.bottom) {
            mon.other_set.Delete(h)
            mon.other_order.RemoveAt(i)
            continue
        }
        i++
    }
    ; 扫描当前显示器上所有未分类窗口，将新窗口追加到 other_order 末尾
    WinGet, allIds, List
    Loop, % allIds {
        h := allIds%A_Index%
        if (IsExcluded(h))
            continue
        wa := GetMonitorWorkArea(h)
        if (wa.left != mon.wa.left || wa.top != mon.wa.top
         || wa.right != mon.wa.right || wa.bottom != mon.wa.bottom)
            continue
        ; 跳过已归入任意屏幕分类的窗口
        isClassified := false
        for mi, m in monitors {
            if (ObjHasKey(m.first_set, h) || ObjHasKey(m.second_set, h)) {
                isClassified := true
                break
            }
        }
        if (isClassified)
            continue
        ; 浮动面板检测：窗口拥有者已在分类组中，则跳过
        if (IsFloatingPanelOfClassified(h))
            continue
        if (ObjHasKey(mon.other_set, h))
            continue
        mon.other_set[h] := true
        mon.other_order.Push(h)
    }
}

; ============================================================
; 全局重扫描：清理所有窗口状态，自动归类贴半屏的窗口
; ============================================================
ReclassifyAllWindows() {
    global monitors, window_original
    ; 清理所有监视器分组中的失效句柄
    for idx, mon in monitors {
        CleanList(mon.first_order, mon.first_set)
        CleanList(mon.second_order, mon.second_set)
        CleanList(mon.other_order, mon.other_set)
    }
    ; 扫描所有窗口，自动归类贴半屏的未分类窗口
    WinGet, allIds, List
    Loop, % allIds {
        h := allIds%A_Index%
        if (IsExcluded(h))
            continue
        if (h = A_ScriptHwnd)
            continue
        ; 跳过已归入任意分组的窗口
        already := false
        for idx, mon in monitors {
            if (ObjHasKey(mon.first_set, h) || ObjHasKey(mon.second_set, h)) {
                already := true
                break
            }
        }
        if (already)
            continue
        ; 检测是否贴半屏
        side := DetectHalfGroup(h)
        if (side = "")
            continue
        ; 自动归入对应分组
        SaveOriginalIfFirst(h)
        mon := GetMonitorData(h)
        if (side = "first") {
            mon.first_set[h] := true
            mon.first_order.Push(h)
        } else {
            mon.second_set[h] := true
            mon.second_order.Push(h)
        }
    }
}

CycleNext(list, set := "", active_hwnd := "") {
    if (list.Length() = 0)
        return
    active := active_hwnd ? active_hwnd : WinExist("A")
    startIdx := 0
    for idx, h in list {
        if (h = active) {
            startIdx := idx
            break
        }
    }
    maxAttempts := list.Length()
    i := 0
    while (i < maxAttempts) {
        nextIdx := (startIdx = 0) ? 1 : Mod(startIdx, list.Length()) + 1
        if (list.Length() = 1 && list[1] = active)
            return
        target := list[nextIdx]
        if (!WinExist("ahk_id " . target)) {
            if (IsObject(set))
                set.Delete(target)
            list.RemoveAt(nextIdx)
            if (nextIdx <= startIdx && startIdx > 0)
                startIdx--
            if (list.Length() = 0)
                return
            i++
            continue
        }
        if (target != active || list.Length() = 1) {
            WinRestore, ahk_id %target%
            DllCall("SetForegroundWindow", "ptr", target)
            WinActivate, ahk_id %target%
            return
        }
        startIdx := nextIdx
        i++
    }
}

; 其他窗口轮换（带跨组回退 + 进程名匹配 + 记忆上次位置）
CycleOtherFallback(mon, active_hwnd := "") {
    global g_last_other_hwnd
    list := mon.other_order
    if (list.Length() = 0)
        return
    active := active_hwnd ? active_hwnd : WinExist("A")
    startIdx := 0
    ; 1) 先精确查找当前活动窗口在列表中的位置
    for idx, h in list {
        if (h = active) {
            startIdx := idx
            break
        }
    }
    ; 2) 精确匹配失败 → 按进程名匹配（跨组：活动窗口已归入 first/second，但同进程有其他窗口在 other 中）
    if (startIdx = 0) {
        WinGet, activeProc, ProcessName, ahk_id %active%
        if (activeProc != "") {
            for idx, h in list {
                if (h = active)
                    continue
                WinGet, hProc, ProcessName, ahk_id %h%
                if (hProc = activeProc) {
                    startIdx := idx
                    break
                }
            }
        }
    }
    ; 3) 进程名也无法匹配 → 使用记忆的上次轮换位置
    if (startIdx = 0 && g_last_other_hwnd != 0) {
        for idx, h in list {
            if (h = g_last_other_hwnd) {
                startIdx := idx
                break
            }
        }
    }
    maxAttempts := list.Length()
    i := 0
    while (i < maxAttempts) {
        nextIdx := (startIdx = 0) ? 1 : Mod(startIdx, list.Length()) + 1
        if (list.Length() = 1 && list[1] = active)
            return
        target := list[nextIdx]
        if (!WinExist("ahk_id " . target)) {
            mon.other_set.Delete(target)
            list.RemoveAt(nextIdx)
            if (nextIdx <= startIdx && startIdx > 0)
                startIdx--
            if (list.Length() = 0)
                return
            i++
            continue
        }
        if (target != active || list.Length() = 1) {
            DllCall("SetForegroundWindow", "ptr", target)
            WinActivate, ahk_id %target%
            g_last_other_hwnd := target  ; 记忆本次激活的窗口
            return
        }
        startIdx := nextIdx
        i++
    }
}

; --- Resize window to a percentage of monitor work area, centered ---
ResizeToPercent(hwnd, percent) {
    wa := GetMonitorWorkArea(hwnd)
    fullW := wa.right - wa.left
    fullH := wa.bottom - wa.top
    ratio := percent / 100.0
    newW := Round(fullW * ratio)
    newH := Round(fullH * ratio)
    newX := wa.left + (fullW - newW) // 2
    newY := wa.top + (fullH - newH) // 2
    WinRestore, ahk_id %hwnd%
    WinMove, ahk_id %hwnd%, , % newX, % newY, % newW, % newH
}

; --- Scan existing windows, auto-classify half-snapped ones ---
ClassifyExistingWindows() {
    global monitors
    foundFirst := 0
    foundSecond := 0

    WinGet, allIds, List
    Loop, % allIds {
        h := allIds%A_Index%
        if (IsExcluded(h))
            continue

        ; Skip if already classified in any monitor
        already := false
        for idx, mon in monitors {
            if (ObjHasKey(mon.first_set, h) || ObjHasKey(mon.second_set, h)) {
                already := true
                break
            }
        }
        if (already)
            continue

        side := DetectHalfGroup(h)
        if (side = "")
            continue

        SaveOriginalIfFirst(h)
        mon := GetMonitorData(h)
        if (side = "first") {
            if (!ObjHasKey(mon.first_set, h)) {
                mon.first_set[h] := true
                mon.first_order.Push(h)
                foundFirst++
            }
        } else {
            if (!ObjHasKey(mon.second_set, h)) {
                mon.second_set[h] := true
                mon.second_order.Push(h)
                foundSecond++
            }
        }
    }
    if (foundFirst > 0 || foundSecond > 0)
        ShowOSD("已识别: " . foundFirst . "/" . foundSecond)
}

; ============================================================
; Cleanup
; ============================================================
CleanupWindows:
    for idx, mon in monitors {
        CleanList(mon.first_order, mon.first_set)
        CleanList(mon.second_order, mon.second_set)
        CleanList(mon.other_order, mon.other_set)
    }
    toDelete := []
    for hwnd, val in window_original {
        if (!WinExist("ahk_id " . hwnd))
            toDelete.Push(hwnd)
    }
    for idx, hwnd in toDelete
        window_original.Delete(hwnd)
return

; ============================================================
; Hotkeys
; ============================================================

; Alt+Q : assign to first group (横屏=左，竖屏=上)
!q::
    hwnd := GetTrueActiveWindow()
    mon := GetMonitorData(hwnd)
    lbl := GetGroupLabel(mon)
    if (AssignWindow(hwnd, "first"))
        ShowOSD("<- " . lbl.first, hwnd)
return

; Alt+E : assign to second group (横屏=右，竖屏=下)
!e::
    hwnd := GetTrueActiveWindow()
    mon := GetMonitorData(hwnd)
    lbl := GetGroupLabel(mon)
    if (AssignWindow(hwnd, "second"))
        ShowOSD("-> " . lbl.second, hwnd)
return

; Alt+W : restore to other (移出分组)
!w::
    hwnd := GetTrueActiveWindow()
    mon := GetMonitorData(hwnd)
    lbl := GetGroupLabel(mon)
    isFirst  := ObjHasKey(mon.first_set, hwnd)
    isSecond := ObjHasKey(mon.second_set, hwnd)
    if (!isFirst && !isSecond)
        return
    fromSide := isFirst ? lbl.first : lbl.second
    if (isFirst) {
        mon.first_set.Delete(hwnd)
        RemoveFromList(mon.first_order, hwnd)
    }
    if (isSecond) {
        mon.second_set.Delete(hwnd)
        RemoveFromList(mon.second_order, hwnd)
    }
    if (ObjHasKey(window_original, hwnd)) {
        orig := window_original[hwnd]
        WinRestore, ahk_id %hwnd%
        WinMove, ahk_id %hwnd%, , % orig.x, % orig.y, % orig.w, % orig.h
    } else {
        wa := mon.wa
        fullW := wa.right - wa.left
        fullH := wa.bottom - wa.top
        newW := 800, newH := 600
        newX := wa.left + (fullW - newW) // 2
        newY := wa.top + (fullH - newH) // 2
        WinRestore, ahk_id %hwnd%
        WinMove, ahk_id %hwnd%, , % newX, % newY, % newW, % newH
    }
    WinActivate, ahk_id %hwnd%
    ShowOSD("恢复至其他，原" . fromSide, hwnd)
return

; Alt+J : show classification status of all windows
!j::
    GoSub, ShowStatus
return

; Alt+1 : cycle first group (横屏=左侧，竖屏=上方)
!1::
    hwnd := GetTrueActiveWindow()
    ReclassifyAllWindows()
    mon := GetMonitorData(hwnd)
    SyncGroupOrder(mon)
    CycleNext(mon.first_order, mon.first_set, hwnd)
return

; Alt+2 : cycle unassigned (other) windows on current monitor (横屏=中间, 竖屏=中间)
!2::
    hwnd := GetTrueActiveWindow()
    ReclassifyAllWindows()
    mon := GetMonitorData(hwnd)
    SyncGroupOrder(mon)
    ShowOSD("其他窗口共 " . mon.other_order.Length() . " 个", hwnd)
    CycleOtherFallback(mon, hwnd)
return

; Alt+3 : cycle second group (横屏=右侧，竖屏=下方)
!3::
    hwnd := GetTrueActiveWindow()
    ReclassifyAllWindows()
    mon := GetMonitorData(hwnd)
    SyncGroupOrder(mon)
    CycleNext(mon.second_order, mon.second_set, hwnd)
return

; Alt+R : swap first and second groups on active monitor
!r::
    hwnd := GetTrueActiveWindow()
    mon := GetMonitorData(hwnd)
    lbl := GetGroupLabel(mon)
    for idx, h in mon.first_order {
        if (WinExist("ahk_id " . h))
            PositionToHalf(h, "second", mon.is_portrait)
    }
    for idx, h in mon.second_order {
        if (WinExist("ahk_id " . h))
            PositionToHalf(h, "first", mon.is_portrait)
    }
    tmpSet        := mon.first_set
    mon.first_set  := mon.second_set
    mon.second_set := tmpSet
    tmpOrder          := mon.first_order
    mon.first_order   := mon.second_order
    mon.second_order  := tmpOrder
    ShowOSD("<-> " . lbl.first . "/" . lbl.second . " 交换", hwnd)
return

; --- Alt+A : full screen (work area)，移出分组 ---
!a::
    hwnd := GetTrueActiveWindow()
    SaveOriginalIfFirst(hwnd)
    UnassignWindow(hwnd)
    ResizeToPercent(hwnd, 100)
    ShowOSD("全屏", hwnd)
return

; --- Alt+S : 80% screen size，移出分组 ---
!s::
    hwnd := GetTrueActiveWindow()
    SaveOriginalIfFirst(hwnd)
    UnassignWindow(hwnd)
    ResizeToPercent(hwnd, 80)
    ShowOSD("80%", hwnd)
return

; --- Alt+D : 60% screen size，移出分组 ---
!d::
    hwnd := GetTrueActiveWindow()
    SaveOriginalIfFirst(hwnd)
    UnassignWindow(hwnd)
    ResizeToPercent(hwnd, 60)
    ShowOSD("60%", hwnd)
return

; ============================================================
; Tray functions
; ============================================================
ShowStatus:
    statusText := ""
    for idx, mon in monitors {
        lbl := GetGroupLabel(mon)
        c1 := mon.first_order.Length()
        c2 := mon.second_order.Length()
        other := GetOtherWindowsForMonitor(mon)
        orient := mon.is_portrait ? "竖" : "横"
        statusText := statusText . "屏幕" . idx . " (" . orient . "): "
        statusText := statusText . lbl.first . ": " . c1 . "个, " . lbl.second . ": " . c2 . "个"
        statusText := statusText . ", 其他: " . other.Length() . "个`n"
    }
    others := GetOtherWindows()
    statusText := statusText . "`n跨屏合计其他: " . others.Length() . "个窗口"
    MsgBox, 64, 窗口分类状态, %statusText%
return

ReloadScript:
    Reload
return

ExitScript:
    ExitApp
return
