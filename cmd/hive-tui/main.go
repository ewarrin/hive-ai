package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gdamore/tcell/v2"
)

// Colors
var (
	styleDefault = tcell.StyleDefault
	styleHeader  = tcell.StyleDefault.Bold(true)
	styleDim     = tcell.StyleDefault.Dim(true)
	styleCyan    = tcell.StyleDefault.Foreground(tcell.ColorTeal)
	styleGreen   = tcell.StyleDefault.Foreground(tcell.ColorGreen)
	styleYellow  = tcell.StyleDefault.Foreground(tcell.ColorYellow)
	styleRed     = tcell.StyleDefault.Foreground(tcell.ColorRed)
)

// Data structures
type RunData struct {
	RunID        string `json:"run_id"`
	EpicID       string `json:"epic_id"`
	Objective    string `json:"objective"`
	Status       string `json:"status"`
	CurrentAgent string `json:"current_agent"`
	StartTime    int64  `json:"start_time"`
}

type Task struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Status string `json:"status"`
}

type CostData struct {
	TotalCost float64 `json:"total_cost_usd"`
}

type AppState struct {
	hiveDir   string
	runID     string
	runData   RunData
	tasks     []Task
	cost      CostData
	agents    []AgentStatus
	output    []string
	lastFetch time.Time
}

type AgentStatus struct {
	Name    string
	Done    bool
	Running bool
}

func main() {
	// Find .hive directory
	hiveDir := os.Getenv("HIVE_DIR")
	if hiveDir == "" {
		hiveDir = ".hive"
	}

	if _, err := os.Stat(hiveDir); os.IsNotExist(err) {
		fmt.Println("No .hive directory found. Run 'hive init' first.")
		os.Exit(1)
	}

	// Find latest run
	runID := findLatestRun(hiveDir)
	if runID == "" {
		fmt.Println("No runs found. Start a workflow with: hive run \"your objective\"")
		os.Exit(0)
	}

	// Initialize screen
	screen, err := tcell.NewScreen()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating screen: %v\n", err)
		os.Exit(1)
	}
	if err := screen.Init(); err != nil {
		fmt.Fprintf(os.Stderr, "Error initializing screen: %v\n", err)
		os.Exit(1)
	}
	defer screen.Fini()

	screen.SetStyle(styleDefault)
	screen.Clear()

	// App state
	state := &AppState{
		hiveDir: hiveDir,
		runID:   runID,
		agents: []AgentStatus{
			{Name: "architect"},
			{Name: "implementer"},
			{Name: "ui-designer"},
			{Name: "tester"},
			{Name: "reviewer"},
			{Name: "documenter"},
		},
	}

	// Initial data load
	state.refresh()

	// Event loop
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	eventChan := make(chan tcell.Event)
	go func() {
		for {
			eventChan <- screen.PollEvent()
		}
	}()

	for {
		render(screen, state)
		screen.Show()

		select {
		case ev := <-eventChan:
			switch ev := ev.(type) {
			case *tcell.EventKey:
				switch ev.Key() {
				case tcell.KeyEscape, tcell.KeyCtrlC:
					return
				case tcell.KeyRune:
					switch ev.Rune() {
					case 'q', 'Q':
						return
					case 'r', 'R':
						state.refresh()
					}
				}
			case *tcell.EventResize:
				screen.Sync()
			}
		case <-ticker.C:
			state.refresh()
		}
	}
}

func (s *AppState) refresh() {
	s.runData = loadRunData(s.hiveDir)
	s.tasks = loadTasks()
	s.cost = loadCost(s.hiveDir, s.runID)
	s.updateAgentStatus()
	s.output = loadLatestOutput(s.hiveDir, s.runID, 6)
	s.lastFetch = time.Now()
}

func (s *AppState) updateAgentStatus() {
	outputDir := filepath.Join(s.hiveDir, "runs", s.runID, "output")
	for i := range s.agents {
		agentFile := filepath.Join(outputDir, s.agents[i].Name+".txt")
		if _, err := os.Stat(agentFile); err == nil {
			s.agents[i].Done = true
			s.agents[i].Running = s.agents[i].Name == s.runData.CurrentAgent
		} else {
			s.agents[i].Done = false
			s.agents[i].Running = s.agents[i].Name == s.runData.CurrentAgent
		}
	}
}

func render(s tcell.Screen, state *AppState) {
	s.Clear()
	w, h := s.Size()
	row := 0

	// Header box
	drawBox(s, 0, 0, w-1, 4, "Hive Status")
	row = 1

	// Run info
	status := state.runData.Status
	if status == "" {
		status = "unknown"
	}
	statusStyle := styleDim
	statusIcon := "○"
	switch status {
	case "running", "in_progress":
		statusStyle = styleGreen
		statusIcon = "●"
	case "complete":
		statusStyle = styleGreen
		statusIcon = "✓"
	case "failed":
		statusStyle = styleRed
		statusIcon = "✗"
	}

	drawText(s, 2, row, styleDim, "Run:")
	drawText(s, 7, row, styleHeader, state.runID)
	drawText(s, 24, row, statusStyle, statusIcon+" "+status)
	drawText(s, 40, row, styleDim, fmt.Sprintf("Cost: $%.2f", state.cost.TotalCost))
	row++

	obj := truncate(state.runData.Objective, w-14)
	drawText(s, 2, row, styleDim, "Objective:")
	drawText(s, 13, row, styleDefault, obj)
	row += 2

	// Pipeline section
	drawBox(s, 0, row, w-1, row+len(state.agents)+2, "Pipeline")
	row++
	for _, agent := range state.agents {
		icon := "○"
		style := styleDim
		if agent.Running {
			icon = "●"
			style = styleYellow
		} else if agent.Done {
			icon = "✓"
			style = styleGreen
		}
		drawText(s, 2, row, style, icon)
		drawText(s, 4, row, styleDefault, agent.Name)
		row++
	}
	row += 2

	// Tasks section
	maxTasks := 5
	taskBoxHeight := min(len(state.tasks), maxTasks) + 2
	if len(state.tasks) == 0 {
		taskBoxHeight = 3
	}
	drawBox(s, 0, row, w-1, row+taskBoxHeight, "Tasks")
	row++

	if len(state.tasks) == 0 {
		drawText(s, 2, row, styleDim, "No tasks")
		row++
	} else {
		for i, task := range state.tasks {
			if i >= maxTasks {
				drawText(s, 2, row, styleDim, fmt.Sprintf("... and %d more", len(state.tasks)-maxTasks))
				row++
				break
			}
			icon := "○"
			style := styleDim
			switch task.Status {
			case "closed":
				icon = "✓"
				style = styleGreen
			case "in_progress":
				icon = "◐"
				style = styleCyan
			}
			title := truncate(task.Title, w-30)
			drawText(s, 2, row, style, icon)
			drawText(s, 4, row, styleDim, task.ID)
			drawText(s, 24, row, styleDefault, title)
			row++
		}
	}
	row += 2

	// Output section
	outputBoxHeight := min(len(state.output), 6) + 2
	if len(state.output) == 0 {
		outputBoxHeight = 3
	}
	if row+outputBoxHeight < h-2 {
		drawBox(s, 0, row, w-1, row+outputBoxHeight, "Live Output")
		row++
		if len(state.output) == 0 {
			drawText(s, 2, row, styleDim, "No recent output")
		} else {
			for _, line := range state.output {
				line = truncate(strings.TrimSpace(line), w-4)
				drawText(s, 2, row, styleDim, line)
				row++
			}
		}
	}

	// Footer
	drawText(s, 1, h-1, styleDim, "q: quit  r: refresh")
}

func drawBox(s tcell.Screen, x1, y1, x2, y2 int, title string) {
	// Top border
	s.SetContent(x1, y1, '─', nil, styleCyan)
	for x := x1 + 1; x < x2; x++ {
		s.SetContent(x, y1, '─', nil, styleCyan)
	}
	s.SetContent(x2, y1, '─', nil, styleCyan)

	// Title
	if title != "" {
		drawText(s, x1+2, y1, styleHeader, title)
	}

	// Bottom border
	for x := x1; x <= x2; x++ {
		s.SetContent(x, y2, '─', nil, styleCyan)
	}
}

func drawText(s tcell.Screen, x, y int, style tcell.Style, text string) {
	for i, r := range text {
		s.SetContent(x+i, y, r, nil, style)
	}
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	if maxLen <= 3 {
		return s[:maxLen]
	}
	return s[:maxLen-1] + "…"
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// Data loading functions

func findLatestRun(hiveDir string) string {
	runsDir := filepath.Join(hiveDir, "runs")
	entries, err := os.ReadDir(runsDir)
	if err != nil {
		return ""
	}

	var runs []string
	for _, e := range entries {
		if e.IsDir() && !strings.Contains(e.Name(), "_subagents") {
			runs = append(runs, e.Name())
		}
	}

	if len(runs) == 0 {
		return ""
	}

	sort.Sort(sort.Reverse(sort.StringSlice(runs)))
	return runs[0]
}

func loadRunData(hiveDir string) RunData {
	var data RunData
	path := filepath.Join(hiveDir, "scratchpad.json")
	content, err := os.ReadFile(path)
	if err != nil {
		return data
	}
	json.Unmarshal(content, &data)
	return data
}

func loadTasks() []Task {
	var tasks []Task
	cmd := exec.Command("bd", "list", "--json")
	output, err := cmd.Output()
	if err != nil {
		return tasks
	}
	json.Unmarshal(output, &tasks)
	return tasks
}

func loadCost(hiveDir, runID string) CostData {
	var cost CostData
	path := filepath.Join(hiveDir, "runs", runID, "cost.json")
	content, err := os.ReadFile(path)
	if err != nil {
		return cost
	}
	json.Unmarshal(content, &cost)
	return cost
}

func loadLatestOutput(hiveDir, runID string, lines int) []string {
	outputDir := filepath.Join(hiveDir, "runs", runID, "output")
	entries, err := os.ReadDir(outputDir)
	if err != nil {
		return nil
	}

	var latest string
	var latestTime time.Time
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".txt") {
			info, err := e.Info()
			if err == nil && info.ModTime().After(latestTime) {
				latestTime = info.ModTime()
				latest = filepath.Join(outputDir, e.Name())
			}
		}
	}

	if latest == "" {
		return nil
	}

	content, err := os.ReadFile(latest)
	if err != nil {
		return nil
	}

	allLines := strings.Split(string(content), "\n")
	if len(allLines) <= lines {
		return allLines
	}
	return allLines[len(allLines)-lines-1 : len(allLines)-1]
}
