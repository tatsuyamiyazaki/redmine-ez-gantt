(function () {
  "use strict";

  var DAY_WIDTH = 24;
  var ROW_HEIGHT = 32;
  var LEFT_PANE_WIDTH = 320;
  var MS_PER_DAY = 24 * 60 * 60 * 1000;

  var state = {
    root: null,
    issues: [],
    issueMap: new Map(),
    pendingSaves: new Map(),
    pendingProgressSaves: new Map(),
    saveSeq: 0,
    progressSaveSeq: 0,
    leftPaneWidth: LEFT_PANE_WIDTH,
    leftPaneCollapsed: false,
    flash: null
  };

  function parseDate(value) {
    if (!value) {
      return null;
    }

    var parts = value.split("-");
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  }

  function formatDate(date) {
    var year = date.getFullYear();
    var month = String(date.getMonth() + 1).padStart(2, "0");
    var day = String(date.getDate()).padStart(2, "0");
    return year + "-" + month + "-" + day;
  }

  function addDays(date, days) {
    var next = new Date(date.getTime());
    next.setDate(next.getDate() + days);
    return next;
  }

  function daysBetween(from, to) {
    return Math.round((to.getTime() - from.getTime()) / MS_PER_DAY);
  }

  function cloneIssue(issue) {
    return Object.assign({}, issue);
  }

  function csrfToken() {
    var meta = document.querySelector("meta[name='csrf-token']");
    return meta ? meta.getAttribute("content") : "";
  }

  function issueUpdateUrl(issueId) {
    var template = state.root && state.root.dataset.issueUpdateUrlTemplate;
    if (template) {
      return template.replace("__ISSUE_ID__", encodeURIComponent(issueId));
    }

    return "/easy_gantt/issues/" + encodeURIComponent(issueId);
  }

  function createElement(tagName, className, text) {
    var element = document.createElement(tagName);

    if (className) {
      element.className = className;
    }

    if (text !== undefined && text !== null) {
      element.textContent = text;
    }

    return element;
  }

  function rebuildIssueMap() {
    state.issueMap = new Map();
    state.issues.forEach(function (issue) {
      state.issueMap.set(issue.id, issue);
    });
  }

  function replaceIssue(issue) {
    for (var i = 0; i < state.issues.length; i += 1) {
      if (state.issues[i].id === issue.id) {
        state.issues[i] = issue;
        rebuildIssueMap();
        return;
      }
    }

    state.issues.push(issue);
    rebuildIssueMap();
  }

  function buildIssueMeta(issues) {
    var byId = {};
    var childrenByParentId = {};

    issues.forEach(function (issue) {
      byId[issue.id] = issue;

      if (issue.parent_issue_id) {
        childrenByParentId[issue.parent_issue_id] = childrenByParentId[issue.parent_issue_id] || [];
        childrenByParentId[issue.parent_issue_id].push(issue.id);
      }
    });

    return {
      byId: byId,
      childrenByParentId: childrenByParentId
    };
  }

  function orderedIssues(issues) {
    var meta = buildIssueMeta(issues);
    var originalIndex = {};
    var ordered = [];
    var visited = {};

    issues.forEach(function (issue, index) {
      originalIndex[issue.id] = index;
    });

    Object.keys(meta.childrenByParentId).forEach(function (parentId) {
      meta.childrenByParentId[parentId].sort(function (leftId, rightId) {
        return originalIndex[leftId] - originalIndex[rightId];
      });
    });

    function visit(issue) {
      if (!issue || visited[issue.id]) {
        return;
      }

      visited[issue.id] = true;
      ordered.push(issue);

      (meta.childrenByParentId[issue.id] || []).forEach(function (childId) {
        visit(meta.byId[childId]);
      });
    }

    issues.forEach(function (issue) {
      if (!issue.parent_issue_id || !meta.byId[issue.parent_issue_id]) {
        visit(issue);
      }
    });

    issues.forEach(function (issue) {
      visit(issue);
    });

    return ordered;
  }

  function issueDepth(issue, byId) {
    var depth = 0;
    var current = issue;
    var visited = {};

    while (current && current.parent_issue_id && byId[current.parent_issue_id] && !visited[current.parent_issue_id]) {
      visited[current.parent_issue_id] = true;
      depth += 1;
      current = byId[current.parent_issue_id];
    }

    return depth;
  }

  function dateRange(issues) {
    var today = new Date();
    today = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    var minDate = today;
    var maxDate = today;

    issues.forEach(function (issue) {
      [parseDate(issue.start_date), parseDate(issue.due_date)].forEach(function (date) {
        if (!date) {
          return;
        }

        if (date < minDate) {
          minDate = date;
        }

        if (date > maxDate) {
          maxDate = date;
        }
      });
    });

    return {
      start: minDate,
      end: maxDate,
      today: today,
      days: daysBetween(minDate, maxDate) + 1
    };
  }

  function namedValue(value) {
    return value && value.name ? value.name : "";
  }

  function doneRatio(issue) {
    var ratio = Number(issue && issue.done_ratio);

    if (!isFinite(ratio)) {
      return 0;
    }

    return Math.max(0, Math.min(100, Math.round(ratio)));
  }

  function isOverdueIssue(issue) {
    var today = new Date();
    var dueDate = parseDate(issue && issue.due_date);

    today = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    return !!dueDate && dueDate < today && doneRatio(issue) < 100;
  }

  function isInProgressIssue(issue) {
    var statusName = namedValue(issue && issue.status).toLowerCase();
    return statusName === "進行中" || statusName === "in progress" || statusName === "progress";
  }

  function barDoneRatio(issue) {
    return doneRatio(issue);
  }

  function isDescendantIssue(candidateParent, issue, byId) {
    var current = candidateParent;
    var visited = {};

    while (current && current.parent_issue_id && byId[current.parent_issue_id] && !visited[current.parent_issue_id]) {
      if (current.parent_issue_id === issue.id) {
        return true;
      }

      visited[current.parent_issue_id] = true;
      current = byId[current.parent_issue_id];
    }

    return false;
  }

  function showFlashMessage(type, message) {
    var element = state.root && state.root.querySelector(".easy-gantt-flash");
    state.flash = {
      type: type,
      message: message || ""
    };

    if (!element) {
      return;
    }

    element.className = "easy-gantt-flash easy-gantt-flash--" + type;
    element.textContent = message || "";
  }

  function toggleLeftPane() {
    state.leftPaneCollapsed = !state.leftPaneCollapsed;
    renderGantt();
  }

  function renderToolbar() {
    var toolbar = createElement("div", "easy-gantt__toolbar");
    var toggleButton = createElement(
      "button",
      "easy-gantt__toolbar-button",
      state.leftPaneCollapsed ? "チケット一覧を表示" : "チケット一覧を閉じる"
    );

    toggleButton.type = "button";
    toggleButton.addEventListener("click", toggleLeftPane);
    toolbar.appendChild(toggleButton);

    return toolbar;
  }

  function attachLeftPaneResize(handle) {
    var drag = null;

    handle.addEventListener("pointerdown", function (event) {
      if (state.leftPaneCollapsed) {
        return;
      }

      event.preventDefault();
      drag = {
        pointerId: event.pointerId,
        startClientX: event.clientX,
        startWidth: state.leftPaneWidth
      };
      handle.setPointerCapture(event.pointerId);
      handle.classList.add("easy-gantt__pane-resizer--dragging");
    });

    handle.addEventListener("pointermove", function (event) {
      var leftPane;
      var nextWidth;

      if (!drag || event.pointerId !== drag.pointerId) {
        return;
      }

      nextWidth = drag.startWidth + event.clientX - drag.startClientX;
      state.leftPaneWidth = Math.max(220, Math.min(560, nextWidth));
      leftPane = state.root && state.root.querySelector(".easy-gantt__left-pane");
      if (leftPane) {
        leftPane.style.width = state.leftPaneWidth + "px";
        leftPane.style.flexBasis = state.leftPaneWidth + "px";
      }
    });

    function endDrag(event) {
      if (!drag || event.pointerId !== drag.pointerId) {
        return;
      }

      drag = null;
      handle.classList.remove("easy-gantt__pane-resizer--dragging");
    }

    handle.addEventListener("pointerup", endDrag);
    handle.addEventListener("pointercancel", endDrag);
  }

  function setBarStatus(issueId, className, clearDelay) {
    var bar = state.root && state.root.querySelector("[data-gantt-issue-id='" + issueId + "']");

    if (!bar) {
      return;
    }

    if (className) {
      bar.classList.add(className);
    }

    if (clearDelay) {
      window.setTimeout(function () {
        var currentBar = state.root && state.root.querySelector("[data-gantt-issue-id='" + issueId + "']");
        if (currentBar) {
          currentBar.classList.remove(className);
        }
      }, clearDelay);
    }
  }

  function renderHeader(range) {
    var header = createElement("div", "easy-gantt__date-header");
    var monthRow = createElement("div", "easy-gantt__month-row");
    var dayRow = createElement("div", "easy-gantt__day-row");
    var monthStart = 0;

    header.style.width = range.days * DAY_WIDTH + "px";

    while (monthStart < range.days) {
      var monthDate = addDays(range.start, monthStart);
      var month = monthDate.getMonth();
      var year = monthDate.getFullYear();
      var monthDays = 0;
      var monthCell = createElement("div", "easy-gantt__month-cell", year + "/" + String(month + 1).padStart(2, "0"));

      while (monthStart + monthDays < range.days) {
        var currentDate = addDays(range.start, monthStart + monthDays);
        if (currentDate.getFullYear() !== year || currentDate.getMonth() !== month) {
          break;
        }

        monthDays += 1;
      }

      monthCell.style.width = monthDays * DAY_WIDTH + "px";
      monthRow.appendChild(monthCell);
      monthStart += monthDays;
    }

    for (var i = 0; i < range.days; i += 1) {
      var date = addDays(range.start, i);
      var cell = createElement("div", "easy-gantt__date-cell");
      cell.style.width = DAY_WIDTH + "px";
      cell.textContent = String(date.getDate());
      cell.title = formatDate(date);

      if (date.getDate() === 1) {
        cell.classList.add("easy-gantt__date-cell--month-start");
      }

      if (date.getDay() === 0) {
        cell.classList.add("easy-gantt__date-cell--sunday");
      } else if (date.getDay() === 6) {
        cell.classList.add("easy-gantt__date-cell--saturday");
      }

      dayRow.appendChild(cell);
    }

    header.appendChild(monthRow);
    header.appendChild(dayRow);
    return header;
  }

  function barGeometry(issue, range) {
    var startDate = parseDate(issue.start_date);
    var dueDate = parseDate(issue.due_date);

    if (!startDate || !dueDate || startDate > dueDate) {
      return null;
    }

    return {
      left: daysBetween(range.start, startDate) * DAY_WIDTH,
      width: Math.max(DAY_WIDTH, (daysBetween(startDate, dueDate) + 1) * DAY_WIDTH)
    };
  }

  function applyBarGeometry(bar, issue, range) {
    var geometry = barGeometry(issue, range);
    var progress = barDoneRatio(issue);
    var label = "#" + issue.id + " " + issue.subject + " (" + issue.start_date + " - " + issue.due_date + ", " + progress + "%)";
    var progressFill;
    var progressText;

    if (!geometry) {
      return;
    }

    bar.style.left = geometry.left + "px";
    bar.style.width = geometry.width + "px";
    bar.title = label;

    var dateText = bar.querySelector(".easy-gantt__bar-dates");
    if (dateText) {
      dateText.textContent = issue.start_date + " - " + issue.due_date;
    }

    progressFill = bar.querySelector(".easy-gantt__bar-progress");
    if (progressFill) {
      progressFill.style.width = progress + "%";
    }

    progressText = bar.querySelector(".easy-gantt__bar-progress-label");
    if (progressText) {
      progressText.textContent = progress + "%";
    }
  }

  function dragDates(mode, originalStart, originalDue, deltaDays) {
    var startDate = parseDate(originalStart);
    var dueDate = parseDate(originalDue);

    if (mode === "move") {
      startDate = addDays(startDate, deltaDays);
      dueDate = addDays(dueDate, deltaDays);
    } else if (mode === "resize-start") {
      startDate = addDays(startDate, deltaDays);
    } else if (mode === "resize-end") {
      dueDate = addDays(dueDate, deltaDays);
    }

    if (startDate > dueDate) {
      return null;
    }

    return {
      start_date: formatDate(startDate),
      due_date: formatDate(dueDate)
    };
  }

  function updateIssueDatesOptimistically(issueId, nextStartDate, nextDueDate) {
    var issue = state.issueMap.get(issueId);
    var startDate = parseDate(nextStartDate);
    var dueDate = parseDate(nextDueDate);
    var requestId;
    var previousIssue;

    if (!issue || !issue.editable) {
      return null;
    }

    if (!startDate || !dueDate || startDate > dueDate) {
      showFlashMessage("error", "Start date must be on or before due date.");
      setBarStatus(issueId, "is-error", 1600);
      return null;
    }

    previousIssue = cloneIssue(issue);
    requestId = state.saveSeq + 1;
    state.saveSeq = requestId;
    state.pendingSaves.set(issueId, requestId);

    issue.start_date = nextStartDate;
    issue.due_date = nextDueDate;
    renderGantt();
    setBarStatus(issueId, "is-saving");
    showFlashMessage("info", "Saving #" + issueId + "...");

    return {
      requestId: requestId,
      previousIssue: previousIssue
    };
  }

  function saveIssueDates(issueId, nextStartDate, nextDueDate, requestId) {
    return fetch(issueUpdateUrl(issueId), {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken()
      },
      body: JSON.stringify({
        issue: {
          start_date: nextStartDate,
          due_date: nextDueDate
        }
      })
    }).then(function (response) {
      return response.json().catch(function () {
        return {};
      }).then(function (data) {
        if (!response.ok || !data.success) {
          throw new Error((data.errors || ["Could not save issue dates."]).join(", "));
        }

        return {
          issue: data.issue,
          requestId: requestId
        };
      });
    });
  }

  function updateIssueProgressOptimistically(issueId, nextDoneRatio) {
    var issue = state.issueMap.get(issueId);
    var requestId;
    var previousIssue;

    nextDoneRatio = Number(nextDoneRatio);

    if (!issue || !issue.editable) {
      return null;
    }

    if (!isFinite(nextDoneRatio) || nextDoneRatio < 0 || nextDoneRatio > 100) {
      showFlashMessage("error", "Progress must be an integer between 0 and 100.");
      setBarStatus(issueId, "is-error", 1600);
      return null;
    }

    nextDoneRatio = Math.round(nextDoneRatio);
    previousIssue = cloneIssue(issue);
    requestId = state.progressSaveSeq + 1;
    state.progressSaveSeq = requestId;
    state.pendingProgressSaves.set(issueId, requestId);

    issue.done_ratio = nextDoneRatio;
    renderGantt();
    setBarStatus(issueId, "is-saving");
    showFlashMessage("info", "Saving progress for #" + issueId + "...");

    return {
      requestId: requestId,
      previousIssue: previousIssue,
      doneRatio: nextDoneRatio
    };
  }

  function saveIssueProgress(issueId, nextDoneRatio, requestId) {
    return fetch(issueUpdateUrl(issueId), {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken()
      },
      body: JSON.stringify({
        issue: {
          done_ratio: nextDoneRatio
        }
      })
    }).then(function (response) {
      return response.json().catch(function () {
        return {};
      }).then(function (data) {
        if (!response.ok || !data.success) {
          throw new Error((data.errors || ["Could not save issue progress."]).join(", "));
        }

        return {
          issue: data.issue,
          requestId: requestId
        };
      });
    });
  }

  function rollbackIssueProgress(issueId, previousIssue) {
    if (!previousIssue) {
      return;
    }

    replaceIssue(previousIssue);
    renderGantt();
    setBarStatus(issueId, "is-error", 2400);
  }

  function updateIssueProgress(issueId, nextDoneRatio) {
    var optimisticResult = updateIssueProgressOptimistically(issueId, nextDoneRatio);

    if (!optimisticResult) {
      renderGantt();
      return;
    }

    saveIssueProgress(issueId, optimisticResult.doneRatio, optimisticResult.requestId)
      .then(function (result) {
        if (state.pendingProgressSaves.get(issueId) !== result.requestId) {
          return;
        }

        state.pendingProgressSaves.delete(issueId);
        applyIssueProgressFromServer(result.issue);
        showFlashMessage("success", "Saved progress for #" + issueId + ".");
      })
      .catch(function (error) {
        if (state.pendingProgressSaves.get(issueId) !== optimisticResult.requestId) {
          return;
        }

        state.pendingProgressSaves.delete(issueId);
        rollbackIssueProgress(issueId, optimisticResult.previousIssue);
        showFlashMessage("error", error.message);
      });
  }

  function rollbackIssueDates(issueId, previousIssue) {
    if (!previousIssue) {
      return;
    }

    replaceIssue(previousIssue);
    renderGantt();
    setBarStatus(issueId, "is-error", 2400);
  }

  function applyIssueFromServer(serverIssue) {
    if (!serverIssue) {
      return;
    }

    replaceIssue(Object.assign({}, state.issueMap.get(serverIssue.id) || {}, serverIssue));
    renderGantt();
    setBarStatus(serverIssue.id, "is-saved", 1400);
  }

  function applyIssueDatesFromServer(serverIssue) {
    var current;

    if (!serverIssue) {
      return;
    }

    current = state.issueMap.get(serverIssue.id) || {};
    replaceIssue(Object.assign({}, current, {
      start_date: serverIssue.start_date,
      due_date: serverIssue.due_date
    }));
    renderGantt();
    setBarStatus(serverIssue.id, "is-saved", 1400);
  }

  function applyIssueProgressFromServer(serverIssue) {
    var current;

    if (!serverIssue) {
      return;
    }

    current = state.issueMap.get(serverIssue.id) || {};
    replaceIssue(Object.assign({}, current, {
      done_ratio: serverIssue.done_ratio
    }));
    renderGantt();
    setBarStatus(serverIssue.id, "is-saved", 1400);
  }

  function saveIssueParent(issue, parentIssueId) {
    return fetch(issueUpdateUrl(issue.id) + "/parent", {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken()
      },
      body: JSON.stringify({
        issue: {
          parent_issue_id: parentIssueId
        }
      })
    }).then(function (response) {
      return response.json().then(function (data) {
        if (!response.ok || !data.success) {
          throw new Error((data.errors || ["Could not save issue parent."]).join(", "));
        }

        return data.issue;
      });
    });
  }

  function updateIssueParent(issueId, parentIssueId) {
    var meta = buildIssueMeta(state.issues);
    var issue = meta.byId[issueId];
    var parentIssue = parentIssueId ? meta.byId[parentIssueId] : null;
    var originalParentIssueId;

    if (!issue || !issue.editable) {
      return;
    }

    if (parentIssue && parentIssue.id === issue.id) {
      showFlashMessage("error", "An issue cannot be its own parent.");
      return;
    }

    if (parentIssue && isDescendantIssue(parentIssue, issue, meta.byId)) {
      showFlashMessage("error", "An issue cannot be moved under its descendant.");
      return;
    }

    originalParentIssueId = issue.parent_issue_id || null;
    parentIssueId = parentIssueId || null;

    if (originalParentIssueId === parentIssueId) {
      showFlashMessage("info", "");
      return;
    }

    showFlashMessage("info", "Saving parent for #" + issue.id + "...");

    saveIssueParent(issue, parentIssueId)
      .then(function (savedIssue) {
        replaceIssue(Object.assign({}, state.issueMap.get(savedIssue.id) || {}, savedIssue));
        showFlashMessage("success", "Saved parent for #" + savedIssue.id + ".");
        renderGantt();
      })
      .catch(function (error) {
        issue.parent_issue_id = originalParentIssueId;
        showFlashMessage("error", error.message);
        renderGantt();
      });
  }

  function attachIssueRowDropHandlers(row, issue) {
    row.addEventListener("dragover", function (event) {
      if (state.draggedIssueId && state.draggedIssueId !== issue.id) {
        event.preventDefault();
        row.classList.add("easy-gantt__issue-row--drop-target");
      }
    });

    row.addEventListener("dragleave", function () {
      row.classList.remove("easy-gantt__issue-row--drop-target");
    });

    row.addEventListener("drop", function (event) {
      var draggedIssueId = Number(event.dataTransfer.getData("text/plain") || state.draggedIssueId);

      event.preventDefault();
      row.classList.remove("easy-gantt__issue-row--drop-target");
      updateIssueParent(draggedIssueId, issue.id);
      state.draggedIssueId = null;
    });
  }

  function renderIssueRow(issue, meta) {
    var row = createElement("div", "easy-gantt__issue-row");
    var title = createElement("div", "easy-gantt__issue-title");
    var id = createElement("span", "easy-gantt__issue-id", "#" + issue.id);
    var subject = createElement("span", "easy-gantt__issue-subject", issue.subject);
    var tracker = createElement("span", "easy-gantt__issue-tracker", namedValue(issue.tracker));
    var progressControl = createElement("label", "easy-gantt__progress-control");
    var progressInput = createElement("input", "easy-gantt__progress-input");
    var progressSuffix = createElement("span", "easy-gantt__progress-suffix", "%");

    row.style.height = ROW_HEIGHT + "px";
    row.dataset.issueId = issue.id;

    if (meta.childrenByParentId[issue.id]) {
      row.classList.add("easy-gantt__issue-row--parent");
    }

    if (isOverdueIssue(issue)) {
      row.classList.add("easy-gantt__issue-row--overdue");
    }

    if (issue.editable) {
      row.draggable = true;
      row.classList.add("easy-gantt__issue-row--draggable");
      row.addEventListener("dragstart", function (event) {
        if (event.target.closest(".easy-gantt__progress-control")) {
          event.preventDefault();
          return;
        }

        state.draggedIssueId = issue.id;
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", String(issue.id));
        row.classList.add("easy-gantt__issue-row--dragging");
        showFlashMessage("info", "Drop #" + issue.id + " on another issue, or on the root area.");
      });
      row.addEventListener("dragend", function () {
        state.draggedIssueId = null;
        row.classList.remove("easy-gantt__issue-row--dragging");
      });
    }

    attachIssueRowDropHandlers(row, issue);

    title.style.paddingLeft = 8 + issueDepth(issue, meta.byId) * 18 + "px";
    title.appendChild(id);
    title.appendChild(subject);
    if (tracker.textContent) {
      title.appendChild(tracker);
    }

    progressInput.type = "number";
    progressInput.min = "0";
    progressInput.max = "100";
    progressInput.step = "5";
    progressInput.value = doneRatio(issue);
    progressInput.disabled = !issue.editable;
    progressInput.title = "Progress";
    progressInput.addEventListener("mousedown", function (event) {
      event.stopPropagation();
    });
    progressInput.addEventListener("pointerdown", function (event) {
      event.stopPropagation();
    });
    progressInput.addEventListener("dragstart", function (event) {
      event.preventDefault();
      event.stopPropagation();
    });
    progressInput.addEventListener("change", function () {
      updateIssueProgress(issue.id, progressInput.value);
    });

    progressControl.title = "Progress";
    progressControl.appendChild(progressInput);
    progressControl.appendChild(progressSuffix);

    row.appendChild(title);
    row.appendChild(progressControl);
    return row;
  }

  function renderRootDropZone() {
    var zone = createElement("div", "easy-gantt__root-dropzone", "Drop here to move the issue to root");

    zone.addEventListener("dragover", function (event) {
      if (state.draggedIssueId) {
        event.preventDefault();
        zone.classList.add("easy-gantt__root-dropzone--active");
      }
    });

    zone.addEventListener("dragleave", function () {
      zone.classList.remove("easy-gantt__root-dropzone--active");
    });

    zone.addEventListener("drop", function (event) {
      var draggedIssueId = Number(event.dataTransfer.getData("text/plain") || state.draggedIssueId);

      event.preventDefault();
      zone.classList.remove("easy-gantt__root-dropzone--active");
      updateIssueParent(draggedIssueId, null);
      state.draggedIssueId = null;
    });

    return zone;
  }

  function attachBarDragHandlers(bar, issue, range) {
    var drag = null;

    function dragMode(event) {
      if (event.target.classList.contains("easy-gantt__bar-handle--left")) {
        return "resize-start";
      }

      if (event.target.classList.contains("easy-gantt__bar-handle--right")) {
        return "resize-end";
      }

      return "move";
    }

    function startDrag(event) {
      if (!issue.editable || !issue.start_date || !issue.due_date) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();

      drag = {
        mode: dragMode(event),
        pointerId: event.pointerId,
        startClientX: event.clientX,
        previousIssue: cloneIssue(issue),
        previewDates: {
          start_date: issue.start_date,
          due_date: issue.due_date
        }
      };

      bar.setPointerCapture(event.pointerId);
      bar.classList.add("easy-gantt__bar--dragging");
      showFlashMessage("info", "Editing #" + issue.id + "...");
    }

    function moveDrag(event) {
      var deltaDays;
      var previewIssue;

      if (!drag || event.pointerId !== drag.pointerId) {
        return;
      }

      deltaDays = Math.round((event.clientX - drag.startClientX) / DAY_WIDTH);
      drag.previewDates = dragDates(drag.mode, drag.previousIssue.start_date, drag.previousIssue.due_date, deltaDays);

      if (!drag.previewDates) {
        bar.classList.add("is-error");
        return;
      }

      bar.classList.remove("is-error");
      previewIssue = Object.assign({}, issue, drag.previewDates);
      applyBarGeometry(bar, previewIssue, range);
    }

    function endDrag(event) {
      var dates;
      var optimisticResult;
      var previousIssue;

      if (!drag || event.pointerId !== drag.pointerId) {
        return;
      }

      previousIssue = drag.previousIssue;
      dates = drag.previewDates;
      drag = null;
      bar.classList.remove("easy-gantt__bar--dragging");

      if (!dates) {
        applyBarGeometry(bar, previousIssue, range);
        showFlashMessage("error", "Start date must be on or before due date.");
        setBarStatus(previousIssue.id, "is-error", 1600);
        return;
      }

      if (dates.start_date === previousIssue.start_date && dates.due_date === previousIssue.due_date) {
        applyBarGeometry(bar, previousIssue, range);
        showFlashMessage("info", "");
        return;
      }

      optimisticResult = updateIssueDatesOptimistically(issue.id, dates.start_date, dates.due_date);

      if (!optimisticResult) {
        applyBarGeometry(bar, previousIssue, range);
        return;
      }

      saveIssueDates(issue.id, dates.start_date, dates.due_date, optimisticResult.requestId)
        .then(function (result) {
          if (state.pendingSaves.get(issue.id) !== result.requestId) {
            return;
          }

          state.pendingSaves.delete(issue.id);
          applyIssueDatesFromServer(result.issue);
          showFlashMessage("success", "Saved #" + issue.id + ".");
        })
        .catch(function (error) {
          if (state.pendingSaves.get(issue.id) !== optimisticResult.requestId) {
            return;
          }

          state.pendingSaves.delete(issue.id);
          rollbackIssueDates(issue.id, optimisticResult.previousIssue);
          showFlashMessage("error", error.message);
        });
    }

    bar.addEventListener("pointerdown", startDrag);
    bar.addEventListener("pointermove", moveDrag);
    bar.addEventListener("pointerup", endDrag);
    bar.addEventListener("pointercancel", endDrag);
  }

  function renderGanttBar(issue, range, meta) {
    var geometry = barGeometry(issue, range);
    var isParent = !!meta.childrenByParentId[issue.id];
    var bar;
    var track;
    var progress;
    var leftHandle;
    var rightHandle;
    var text;
    var progressText;

    if (!geometry) {
      return null;
    }

    bar = createElement("div", "easy-gantt__bar easy-gantt-bar");
    track = createElement("span", "easy-gantt__bar-track");
    progress = createElement("span", "easy-gantt__bar-progress");
    leftHandle = createElement("span", "easy-gantt__bar-handle easy-gantt__bar-handle--left");
    rightHandle = createElement("span", "easy-gantt__bar-handle easy-gantt__bar-handle--right");
    text = createElement(
      "span",
      "easy-gantt__bar-label",
      state.leftPaneCollapsed ? "#" + issue.id + " " + issue.subject : (isInProgressIssue(issue) ? "作業中" : "")
    );
    progressText = createElement("span", "easy-gantt__bar-progress-label", barDoneRatio(issue) + "%");

    bar.dataset.ganttIssueId = issue.id;

    if (isParent) {
      bar.classList.add("easy-gantt__bar--parent");
    }

    if (isOverdueIssue(issue)) {
      bar.classList.add("easy-gantt__bar--overdue");
    }

    if (state.pendingSaves.has(issue.id) || state.pendingProgressSaves.has(issue.id)) {
      bar.classList.add("is-saving");
    }

    if (issue.editable) {
      bar.classList.add("easy-gantt__bar--editable");
      attachBarDragHandlers(bar, issue, range);
    } else {
      bar.classList.add("easy-gantt__bar--readonly");
    }

    bar.appendChild(track);
    bar.appendChild(progress);
    bar.appendChild(leftHandle);
    if (!isParent || state.leftPaneCollapsed) {
      if (text.textContent) {
        bar.appendChild(text);
      }
      bar.appendChild(progressText);
    }
    bar.appendChild(rightHandle);
    applyBarGeometry(bar, issue, range);
    return bar;
  }

  function renderChartRows(displayIssues, range, meta) {
    var rows = createElement("div", "easy-gantt__chart-rows");
    rows.style.width = range.days * DAY_WIDTH + "px";

    displayIssues.forEach(function (issue) {
      var row = createElement("div", "easy-gantt__bar-row");
      var bar = renderGanttBar(issue, range, meta);

      row.style.height = ROW_HEIGHT + "px";
      if (bar) {
        row.appendChild(bar);
      }

      rows.appendChild(row);
    });

    return rows;
  }

  function renderTodayLine(range, rowCount) {
    var line = createElement("div", "easy-gantt__today-line");
    line.style.left = daysBetween(range.start, range.today) * DAY_WIDTH + DAY_WIDTH / 2 + "px";
    line.style.height = rowCount * ROW_HEIGHT + "px";
    return line;
  }

  function renderEmpty() {
    state.root.innerHTML = "";
    state.root.appendChild(createElement("div", "easy-gantt__empty", "No issues to display."));
  }

  function renderGantt() {
    var meta;
    var displayIssues;
    var range;
    var flash;
    var rootDropZone;
    var shell;
    var leftPane;
    var rightPane;
    var leftHeader;
    var resizer;
    var chartBody;
    var leftRows;

    if (!state.issues.length) {
      renderEmpty();
      return;
    }

    meta = buildIssueMeta(state.issues);
    displayIssues = orderedIssues(state.issues);
    range = dateRange(state.issues);
    flash = createElement("div", "easy-gantt-flash");
    rootDropZone = renderRootDropZone();
    shell = createElement("div", "easy-gantt__shell");
    leftPane = createElement("div", "easy-gantt__left-pane");
    rightPane = createElement("div", "easy-gantt__right-pane");
    leftHeader = createElement("div", "easy-gantt__left-header", "Issues");
    resizer = createElement("div", "easy-gantt__pane-resizer");
    chartBody = createElement("div", "easy-gantt__chart-body");
    leftRows = document.createDocumentFragment();

    displayIssues.forEach(function (issue) {
      leftRows.appendChild(renderIssueRow(issue, meta));
    });

    shell.classList.toggle("easy-gantt__shell--left-collapsed", state.leftPaneCollapsed);

    if (!state.leftPaneCollapsed) {
      leftPane.style.width = state.leftPaneWidth + "px";
      leftPane.style.flexBasis = state.leftPaneWidth + "px";
      leftPane.appendChild(leftHeader);
      leftPane.appendChild(leftRows);
      attachLeftPaneResize(resizer);
    }

    chartBody.style.width = range.days * DAY_WIDTH + "px";
    chartBody.style.height = displayIssues.length * ROW_HEIGHT + "px";
    chartBody.appendChild(renderChartRows(displayIssues, range, meta));
    chartBody.appendChild(renderTodayLine(range, displayIssues.length));

    rightPane.appendChild(renderHeader(range));
    rightPane.appendChild(chartBody);

    if (!state.leftPaneCollapsed) {
      shell.appendChild(leftPane);
      shell.appendChild(resizer);
    }
    shell.appendChild(rightPane);

    state.root.innerHTML = "";
    state.root.appendChild(flash);
    state.root.appendChild(renderToolbar());
    state.root.appendChild(rootDropZone);
    state.root.appendChild(shell);

    if (state.flash) {
      showFlashMessage(state.flash.type, state.flash.message);
    }
  }

  function renderError() {
    state.root.innerHTML = "";
    state.root.appendChild(createElement("div", "easy-gantt__error", "Could not load Easy Gantt issues."));
  }

  function init(root) {
    var issuesUrl = root.dataset.issuesUrl;
    state.root = root;

    fetch(issuesUrl, {
      credentials: "same-origin",
      headers: {
        Accept: "application/json"
      }
    })
      .then(function (response) {
        if (!response.ok) {
          throw new Error("Failed to load issues");
        }

        return response.json();
      })
      .then(function (issues) {
        state.issues = issues;
        rebuildIssueMap();
        renderGantt();
      })
      .catch(function () {
        renderError();
      });
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = document.getElementById("easy-gantt");

    if (root) {
      init(root);
    }
  });
}());
