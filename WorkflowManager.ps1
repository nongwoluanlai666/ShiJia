param(
    [switch]$SelfTest,
    [switch]$UiSmokeTest,
    [switch]$NetworkSelfTest,
    [switch]$TrayPersistenceTest,
    [switch]$WebSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

public class WorkflowCanvasPanel : Panel
{
    public int CanvasVersion { get { return 2; } }

    public static double DistanceToSegment(double px, double py, double x1, double y1, double x2, double y2)
    {
        double dx = x2 - x1;
        double dy = y2 - y1;
        if (dx == 0 && dy == 0) return System.Math.Sqrt((px - x1) * (px - x1) + (py - y1) * (py - y1));
        double ratio = ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy);
        ratio = System.Math.Max(0, System.Math.Min(1, ratio));
        double nearestX = x1 + ratio * dx;
        double nearestY = y1 + ratio * dy;
        return System.Math.Sqrt((px - nearestX) * (px - nearestX) + (py - nearestY) * (py - nearestY));
    }

    public WorkflowCanvasPanel()
    {
        this.DoubleBuffered = true;
        this.ResizeRedraw = true;
        this.TabStop = true;
        this.SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable, true);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (!this.Focused) this.Focus();
        base.OnMouseDown(e);
    }

    protected override bool IsInputKey(Keys keyData)
    {
        if ((keyData & Keys.KeyCode) == Keys.Delete) return true;
        return base.IsInputKey(keyData);
    }
}

public class WorkflowBufferedFlowLayoutPanel : FlowLayoutPanel
{
    public int ConversationLayoutVersion { get { return 2; } }

    public WorkflowBufferedFlowLayoutPanel()
    {
        this.DoubleBuffered = true;
        this.ResizeRedraw = true;
        this.AutoScroll = true;
        this.FlowDirection = FlowDirection.TopDown;
        this.WrapContents = false;
        this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    protected override Point ScrollToControl(Control activeControl)
    {
        // RichTextBox focus is used for text selection only. Letting WinForms
        // scroll focused children into view makes a click jump to an older bubble.
        return this.DisplayRectangle.Location;
    }
}

public class WorkflowConversationRichTextBox : RichTextBox
{
    private const int WM_SETFOCUS = 0x0007;
    private ScrollableControl scrollHost;
    private int preservedScrollX;
    private int preservedScrollY;
    private bool hasPreservedScroll;
    private bool restoreQueued;

    public int ScrollPreservationVersion { get { return 2; } }

    public ScrollableControl ScrollHost
    {
        get { return scrollHost; }
        set { scrollHost = value; }
    }

    public void CaptureScrollHostPosition()
    {
        if (scrollHost == null || scrollHost.IsDisposed) return;
        preservedScrollX = Math.Max(0, -scrollHost.AutoScrollPosition.X);
        preservedScrollY = Math.Max(0, -scrollHost.AutoScrollPosition.Y);
        hasPreservedScroll = true;
    }

    private void RestoreScrollHostPosition()
    {
        if (!hasPreservedScroll || scrollHost == null || scrollHost.IsDisposed) return;
        scrollHost.AutoScrollPosition = new Point(preservedScrollX, preservedScrollY);
    }

    private void QueueScrollHostRestore()
    {
        RestoreScrollHostPosition();
        if (restoreQueued || IsDisposed || !IsHandleCreated) return;
        restoreQueued = true;
        try
        {
            BeginInvoke((Action)(() =>
            {
                RestoreScrollHostPosition();
                try
                {
                    BeginInvoke((Action)(() =>
                    {
                        RestoreScrollHostPosition();
                        restoreQueued = false;
                    }));
                }
                catch { restoreQueued = false; }
            }));
        }
        catch { restoreQueued = false; }
    }

    protected override void WndProc(ref Message m)
    {
        bool gainingFocus = m.Msg == WM_SETFOCUS;
        if (gainingFocus) CaptureScrollHostPosition();
        base.WndProc(ref m);
        if (gainingFocus) QueueScrollHostRestore();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        CaptureScrollHostPosition();
        base.OnMouseDown(e);
        QueueScrollHostRestore();
    }
}

public class WorkflowRoundedPanel : Panel
{
    private Color fillColor = Color.White;
    private Color borderColor = Color.FromArgb(226, 232, 240);
    private int cornerRadius = 14;
    private float borderWidth = 1f;

    public Color FillColor
    {
        get { return fillColor; }
        set { fillColor = value; Invalidate(); }
    }

    public Color BorderColor
    {
        get { return borderColor; }
        set { borderColor = value; Invalidate(); }
    }

    public int CornerRadius
    {
        get { return cornerRadius; }
        set { cornerRadius = Math.Max(2, value); Invalidate(); }
    }

    public float BorderWidth
    {
        get { return borderWidth; }
        set { borderWidth = Math.Max(0, value); Invalidate(); }
    }

    public WorkflowRoundedPanel()
    {
        this.DoubleBuffered = true;
        this.ResizeRedraw = true;
        this.BackColor = Color.Transparent;
        this.SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
    }

    private GraphicsPath CreatePath(Rectangle rectangle)
    {
        int radius = Math.Min(cornerRadius, Math.Min(rectangle.Width, rectangle.Height) / 2);
        int diameter = Math.Max(2, radius * 2);
        GraphicsPath path = new GraphicsPath();
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (Parent != null) e.Graphics.Clear(Parent.BackColor);
        else e.Graphics.Clear(Color.Transparent);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle rectangle = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        using (GraphicsPath path = CreatePath(rectangle))
        using (SolidBrush brush = new SolidBrush(fillColor))
        {
            e.Graphics.FillPath(brush, path);
            if (borderWidth > 0)
            {
                using (Pen pen = new Pen(borderColor, borderWidth)) e.Graphics.DrawPath(pen, path);
            }
        }
        base.OnPaint(e);
    }
}

public static class WorkflowIconFactory
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    private static GraphicsPath CreateRoundedRectangle(float x, float y, float width, float height, float radius)
    {
        GraphicsPath path = new GraphicsPath();
        float diameter = radius * 2;
        path.AddArc(x, y, diameter, diameter, 180, 90);
        path.AddArc(x + width - diameter, y, diameter, diameter, 270, 90);
        path.AddArc(x + width - diameter, y + height - diameter, diameter, diameter, 0, 90);
        path.AddArc(x, y + height - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static Icon Create(int size)
    {
        int requestedSize = Math.Max(16, size);
        int renderSize = Math.Max(requestedSize, requestedSize * 4);
        size = renderSize;
        Bitmap bitmap = new Bitmap(renderSize, renderSize, PixelFormat.Format32bppArgb);
        Graphics graphics = Graphics.FromImage(bitmap);
        Bitmap outputBitmap = null;
        IntPtr iconHandle = IntPtr.Zero;
        try
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            graphics.Clear(Color.Transparent);

            float inset = Math.Max(1, size * 0.06f);
            using (GraphicsPath background = CreateRoundedRectangle(inset, inset, size - inset * 2, size - inset * 2, size * 0.20f))
            using (SolidBrush backgroundBrush = new SolidBrush(Color.FromArgb(255, 37, 99, 235)))
            {
                graphics.FillPath(backgroundBrush, background);
            }

            float lineWidth = Math.Max(1.4f, size * 0.075f);
            float left = size * 0.27f;
            float middle = size * 0.50f;
            float right = size * 0.73f;
            float top = size * 0.31f;
            float bottom = size * 0.69f;
            using (Pen linePen = new Pen(Color.White, lineWidth))
            {
                linePen.StartCap = LineCap.Round;
                linePen.EndCap = LineCap.Round;
                graphics.DrawLine(linePen, left, top, middle, top);
                graphics.DrawLine(linePen, middle, top, middle, bottom);
                graphics.DrawLine(linePen, middle, bottom, right, bottom);
            }

            float nodeSize = Math.Max(3, size * 0.22f);
            using (SolidBrush nodeBrush = new SolidBrush(Color.White))
            using (SolidBrush accentBrush = new SolidBrush(Color.FromArgb(255, 45, 212, 191)))
            {
                graphics.FillEllipse(nodeBrush, left - nodeSize / 2, top - nodeSize / 2, nodeSize, nodeSize);
                graphics.FillEllipse(nodeBrush, middle - nodeSize / 2, bottom - nodeSize / 2, nodeSize, nodeSize);
                graphics.FillEllipse(accentBrush, right - nodeSize / 2, bottom - nodeSize / 2, nodeSize, nodeSize);
            }

            outputBitmap = new Bitmap(requestedSize, requestedSize, PixelFormat.Format32bppArgb);
            using (Graphics outputGraphics = Graphics.FromImage(outputBitmap))
            {
                outputGraphics.CompositingMode = CompositingMode.SourceCopy;
                outputGraphics.CompositingQuality = CompositingQuality.HighQuality;
                outputGraphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                outputGraphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                outputGraphics.SmoothingMode = SmoothingMode.HighQuality;
                outputGraphics.DrawImage(bitmap, new Rectangle(0, 0, requestedSize, requestedSize), 0, 0, renderSize, renderSize, GraphicsUnit.Pixel);
            }
            iconHandle = outputBitmap.GetHicon();
            return (Icon)Icon.FromHandle(iconHandle).Clone();
        }
        finally
        {
            if (iconHandle != IntPtr.Zero) DestroyIcon(iconHandle);
            if (outputBitmap != null) outputBitmap.Dispose();
            graphics.Dispose();
            bitmap.Dispose();
        }
    }
}

public static class WorkflowNativeMethods
{
    private const int EM_SETMARGINS = 0x00D3;
    private const int EM_GETLINECOUNT = 0x00BA;
    private const int WM_VSCROLL = 0x0115;
    private const int SB_TOP = 6;
    private const int WM_SETREDRAW = 0x000B;
    private const uint RDW_INVALIDATE = 0x0001;
    private const uint RDW_UPDATENOW = 0x0100;
    private const uint RDW_ALLCHILDREN = 0x0080;
    private const uint RDW_FRAME = 0x0400;
    private const int EC_LEFTMARGIN = 0x0001;
    private const int EC_RIGHTMARGIN = 0x0002;
    private const int WM_GETICON = 0x007F;
    private const int WM_SETICON = 0x0080;
    private const int ICON_SMALL = 0;
    private const int ICON_BIG = 1;

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RedrawWindow(IntPtr handle, IntPtr updateRect, IntPtr updateRegion, uint flags);

    [DllImport("user32.dll", EntryPoint = "SetProcessDpiAwarenessContext", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContextNative(IntPtr value);

    [DllImport("shcore.dll", EntryPoint = "SetProcessDpiAwareness", SetLastError = true)]
    private static extern int SetProcessDpiAwarenessNative(int awareness);

    [DllImport("user32.dll", EntryPoint = "SetProcessDPIAware", SetLastError = true)]
    private static extern bool SetProcessDpiAwareNative();

    [DllImport("user32.dll", EntryPoint = "GetDpiForWindow", SetLastError = true)]
    private static extern uint GetDpiForWindowNative(IntPtr handle);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    public static bool EnablePerMonitorDpi()
    {
        try { if (SetProcessDpiAwarenessContextNative(new IntPtr(-4))) return true; } catch { }
        try { if (SetProcessDpiAwarenessNative(2) == 0) return true; } catch { }
        try { return SetProcessDpiAwareNative(); } catch { return false; }
    }

    public static int GetWindowDpi(Form form)
    {
        try
        {
            if (form != null && form.IsHandleCreated)
            {
                uint dpi = GetDpiForWindowNative(form.Handle);
                if (dpi >= 96 && dpi <= 768) return (int)dpi;
            }
        }
        catch { }
        return 96;
    }

    public static void ApplyWindowIcons(Form form, Icon smallIcon, Icon largeIcon)
    {
        if (form == null || !form.IsHandleCreated) return;
        SendMessage(form.Handle, WM_SETICON, new IntPtr(ICON_SMALL), smallIcon.Handle);
        SendMessage(form.Handle, WM_SETICON, new IntPtr(ICON_BIG), largeIcon.Handle);
    }

    public static IntPtr GetWindowIcon(Form form, bool large)
    {
        if (form == null || !form.IsHandleCreated) return IntPtr.Zero;
        return SendMessage(form.Handle, WM_GETICON, new IntPtr(large ? ICON_BIG : ICON_SMALL), IntPtr.Zero);
    }

    public static void ApplyTextMargins(TextBoxBase textBox, int margin)
    {
        if (textBox == null || textBox.IsDisposed) return;
        int packedMargins = (margin << 16) | (margin & 0xffff);
        SendMessage(textBox.Handle, EM_SETMARGINS, new IntPtr(EC_LEFTMARGIN | EC_RIGHTMARGIN), new IntPtr(packedMargins));
    }

    public static int GetRichTextLineCount(RichTextBox textBox)
    {
        if (textBox == null || textBox.IsDisposed || !textBox.IsHandleCreated) return 0;
        return SendMessage(textBox.Handle, EM_GETLINECOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
    }

    public static void ScrollRichTextToTop(RichTextBox textBox)
    {
        if (textBox == null || textBox.IsDisposed || !textBox.IsHandleCreated) return;
        SendMessage(textBox.Handle, WM_VSCROLL, new IntPtr(SB_TOP), IntPtr.Zero);
    }

    public static void SetControlRedraw(Control control, bool enabled)
    {
        if (control == null || control.IsDisposed) return;
        if (!control.IsHandleCreated) control.CreateControl();
        SendMessage(control.Handle, WM_SETREDRAW, enabled ? new IntPtr(1) : IntPtr.Zero, IntPtr.Zero);
        if (enabled) RedrawWindow(control.Handle, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_FRAME);
    }
}

public sealed class WorkflowConPtyProcess : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] private struct COORD { public short X; public short Y; public COORD(short x, short y) { X=x; Y=y; } }
    [StructLayout(LayoutKind.Sequential)] private struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle; public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] private struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public uint dwProcessId; public uint dwThreadId; }
    private const uint HANDLE_FLAG_INHERIT=1, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE=0x00020016, EXTENDED_STARTUPINFO_PRESENT=0x00080000, CREATE_NEW_PROCESS_GROUP=0x00000200, CREATE_UNICODE_ENVIRONMENT=0x00000400, STILL_ACTIVE=259;
    private const int STARTF_USESHOWWINDOW=1; private const short SW_HIDE=0;
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SECURITY_ATTRIBUTES attributes,int size);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern uint CreatePseudoConsole(COORD size,IntPtr input,IntPtr output,uint flags,out IntPtr pseudoConsole);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern void ClosePseudoConsole(IntPtr pseudoConsole);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr size);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returnSize);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CreateProcess(string applicationName,StringBuilder commandLine,IntPtr processAttributes,IntPtr threadAttributes,bool inheritHandles,uint creationFlags,IntPtr environment,string currentDirectory,ref STARTUPINFOEX startup,out PROCESS_INFORMATION processInformation);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool ReadFile(IntPtr file,byte[] buffer,int length,out int read,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool WriteFile(IntPtr file,byte[] buffer,int length,out int written,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool CancelIoEx(IntPtr file,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
    private readonly object gate=new object(); private readonly StringBuilder output=new StringBuilder(); private IntPtr inputWrite=IntPtr.Zero,outputRead=IntPtr.Zero,pseudoConsole=IntPtr.Zero,processHandle=IntPtr.Zero,threadHandle=IntPtr.Zero; private Thread outputThread; private bool disposed;
    public uint ProcessId { get; private set; } public string CommandLine { get; private set; }
    public bool IsRunning { get { if(processHandle==IntPtr.Zero)return false;uint code;try{return GetExitCodeProcess(processHandle,out code)&&code==STILL_ACTIVE;}catch{return false;} } }
    public uint ExitCode { get { uint code=STILL_ACTIVE;if(processHandle!=IntPtr.Zero){try{GetExitCodeProcess(processHandle,out code);}catch{}}return code; } }
    private WorkflowConPtyProcess() { }
    private static string Quote(string value){if(value==null)return "\"\"";StringBuilder b=new StringBuilder();b.Append('"');int slash=0;foreach(char c in value){if(c=='\\'){slash++;continue;}if(c=='"'){b.Append('\\',slash*2+1);b.Append('"');slash=0;continue;}if(slash>0){b.Append('\\',slash);slash=0;}b.Append(c);}if(slash>0)b.Append('\\',slash*2);b.Append('"');return b.ToString();}
    public static WorkflowConPtyProcess Start(string applicationPath,string arguments,string workingDirectory)
    {
        if(String.IsNullOrWhiteSpace(applicationPath))throw new ArgumentException("applicationPath"); if(String.IsNullOrWhiteSpace(workingDirectory)||!Directory.Exists(workingDirectory))throw new DirectoryNotFoundException(workingDirectory);
        WorkflowConPtyProcess result=new WorkflowConPtyProcess(); IntPtr inputRead=IntPtr.Zero,outputWrite=IntPtr.Zero,attributes=IntPtr.Zero,pseudoValue=IntPtr.Zero; SECURITY_ATTRIBUTES security=new SECURITY_ATTRIBUTES();security.nLength=Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));security.bInheritHandle=1;
        try
        {
            if(!CreatePipe(out inputRead,out result.inputWrite,ref security,0))throw new InvalidOperationException(); if(!CreatePipe(out result.outputRead,out outputWrite,ref security,0))throw new InvalidOperationException(); if(!SetHandleInformation(result.inputWrite,HANDLE_FLAG_INHERIT,0))throw new InvalidOperationException(); if(!SetHandleInformation(result.outputRead,HANDLE_FLAG_INHERIT,0))throw new InvalidOperationException();
            uint ptyResult=CreatePseudoConsole(new COORD(160,48),inputRead,outputWrite,0,out result.pseudoConsole); if(ptyResult!=0)throw new InvalidOperationException("ConPTY failed: "+ptyResult); CloseHandle(inputRead);inputRead=IntPtr.Zero;CloseHandle(outputWrite);outputWrite=IntPtr.Zero;
            IntPtr attributeSize=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref attributeSize);if(attributeSize==IntPtr.Zero)throw new InvalidOperationException();attributes=Marshal.AllocHGlobal(attributeSize);if(!InitializeProcThreadAttributeList(attributes,1,0,ref attributeSize))throw new InvalidOperationException();pseudoValue=Marshal.AllocHGlobal(IntPtr.Size);Marshal.WriteIntPtr(pseudoValue,result.pseudoConsole);if(!UpdateProcThreadAttribute(attributes,0,new IntPtr(PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE),pseudoValue,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero))throw new InvalidOperationException();
            STARTUPINFOEX startup=new STARTUPINFOEX();startup.StartupInfo.cb=Marshal.SizeOf(typeof(STARTUPINFOEX));startup.StartupInfo.dwFlags=STARTF_USESHOWWINDOW;startup.StartupInfo.wShowWindow=SW_HIDE;startup.lpAttributeList=attributes;StringBuilder commandBuffer=new StringBuilder(Quote(applicationPath)+(String.IsNullOrWhiteSpace(arguments)?String.Empty:" "+arguments));PROCESS_INFORMATION info;uint flags=EXTENDED_STARTUPINFO_PRESENT|CREATE_NEW_PROCESS_GROUP|CREATE_UNICODE_ENVIRONMENT;if(!CreateProcess(null,commandBuffer,IntPtr.Zero,IntPtr.Zero,false,flags,IntPtr.Zero,workingDirectory,ref startup,out info))throw new InvalidOperationException("ConPTY process start failed: "+Marshal.GetLastWin32Error());
            result.processHandle=info.hProcess;result.threadHandle=info.hThread;result.ProcessId=info.dwProcessId;result.CommandLine=commandBuffer.ToString();result.outputThread=new Thread(result.ReadOutputLoop);result.outputThread.IsBackground=true;result.outputThread.Name="ShiJia Codex Fork Output";result.outputThread.Start();return result;
        }
        catch{if(inputRead!=IntPtr.Zero)CloseHandle(inputRead);if(outputWrite!=IntPtr.Zero)CloseHandle(outputWrite);result.Dispose();throw;}
        finally{if(attributes!=IntPtr.Zero){try{DeleteProcThreadAttributeList(attributes);}catch{}Marshal.FreeHGlobal(attributes);}if(pseudoValue!=IntPtr.Zero)Marshal.FreeHGlobal(pseudoValue);}
    }
    private void ReadOutputLoop(){byte[] buffer=new byte[8192];while(!disposed&&outputRead!=IntPtr.Zero){int count;bool ok;try{ok=ReadFile(outputRead,buffer,buffer.Length,out count,IntPtr.Zero);}catch{break;}if(!ok||count<=0)break;string text;try{text=Encoding.UTF8.GetString(buffer,0,count);}catch{text=String.Empty;}if(text.Length==0)continue;lock(gate){output.Append(text);if(output.Length>32768)output.Remove(0,output.Length-32768);}}}
    public string GetOutputSnapshot(){lock(gate)return output.ToString();}
    public bool WriteInput(string value){if(disposed||inputWrite==IntPtr.Zero||String.IsNullOrEmpty(value))return false;byte[] bytes=Encoding.UTF8.GetBytes(value);int written;try{return WriteFile(inputWrite,bytes,bytes.Length,out written,IntPtr.Zero)&&written==bytes.Length;}catch{return false;}}
    public void Terminate(uint code){if(processHandle!=IntPtr.Zero&&IsRunning){try{TerminateProcess(processHandle,code);}catch{}}}
    public void Dispose(){if(disposed)return;try{if(processHandle!=IntPtr.Zero&&IsRunning)Terminate(1);}catch{}disposed=true;if(outputRead!=IntPtr.Zero){try{CancelIoEx(outputRead,IntPtr.Zero);}catch{}}if(inputWrite!=IntPtr.Zero){try{CloseHandle(inputWrite);}catch{}inputWrite=IntPtr.Zero;}if(outputRead!=IntPtr.Zero){try{CloseHandle(outputRead);}catch{}outputRead=IntPtr.Zero;}if(pseudoConsole!=IntPtr.Zero){try{ClosePseudoConsole(pseudoConsole);}catch{}pseudoConsole=IntPtr.Zero;}if(threadHandle!=IntPtr.Zero){try{CloseHandle(threadHandle);}catch{}threadHandle=IntPtr.Zero;}if(processHandle!=IntPtr.Zero){try{CloseHandle(processHandle);}catch{}processHandle=IntPtr.Zero;}}
}

public class WorkflowMainForm : Form
{
    public bool AllowApplicationExit { get; set; }
}

public sealed class WorkflowSingleInstanceCoordinator : IDisposable
{
    private readonly Mutex mutex;
    private readonly EventWaitHandle activationSignal;
    private readonly bool ownsMutex;

    public bool IsPrimary { get; private set; }

    public WorkflowSingleInstanceCoordinator(string mutexName, string signalName)
    {
        bool signalCreated;
        bool mutexCreated;
        activationSignal = new EventWaitHandle(false, EventResetMode.AutoReset, signalName, out signalCreated);
        mutex = new Mutex(true, mutexName, out mutexCreated);
        IsPrimary = mutexCreated;
        ownsMutex = mutexCreated;
        if (!IsPrimary) activationSignal.Set();
    }

    public bool ConsumeActivationSignal()
    {
        return IsPrimary && activationSignal.WaitOne(0);
    }

    public void Dispose()
    {
        if (ownsMutex)
        {
            try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
        }
        mutex.Dispose();
        activationSignal.Dispose();
        IsPrimary = false;
    }
}

public sealed class WorkflowFileTreeEntry
{
    public string Name { get; set; }
    public string FullPath { get; set; }
    public bool IsDirectory { get; set; }
}

public sealed class WorkflowFileTreeResult
{
    public string DirectoryPath { get; set; }
    public string RequestId { get; set; }
    public int Limit { get; set; }
    public bool IsTruncated { get; set; }
    public string Error { get; set; }
    public List<WorkflowFileTreeEntry> Entries { get; private set; }

    public WorkflowFileTreeResult()
    {
        DirectoryPath = "";
        RequestId = "";
        Error = "";
        Entries = new List<WorkflowFileTreeEntry>();
    }
}

public static class WorkflowFileTreeLoader
{
    private static readonly ConcurrentDictionary<string, byte> ActiveRequests = new ConcurrentDictionary<string, byte>();
    private static readonly ConcurrentDictionary<string, byte> CancelledRequests = new ConcurrentDictionary<string, byte>();

    public static void Cancel(string requestId)
    {
        byte ignored;
        if (!String.IsNullOrWhiteSpace(requestId))
        {
            ActiveRequests.TryRemove(requestId, out ignored);
            CancelledRequests[requestId] = 0;
        }
    }

    private static bool IsCancelled(string requestId)
    {
        return !String.IsNullOrWhiteSpace(requestId) && CancelledRequests.ContainsKey(requestId);
    }

    private static string GetEntryName(string path)
    {
        string name = Path.GetFileName(path);
        return String.IsNullOrWhiteSpace(name) ? path : name;
    }

    public static WorkflowFileTreeResult Enumerate(string directoryPath, int limit, string requestId)
    {
        WorkflowFileTreeResult result = new WorkflowFileTreeResult();
        result.DirectoryPath = directoryPath ?? "";
        result.RequestId = requestId ?? "";
        result.Limit = Math.Max(1, limit);
        try
        {
            if (String.IsNullOrWhiteSpace(directoryPath) || !Directory.Exists(directoryPath))
            {
                result.Error = "目录不存在。";
                return result;
            }

            List<WorkflowFileTreeEntry> directories = new List<WorkflowFileTreeEntry>();
            List<WorkflowFileTreeEntry> files = new List<WorkflowFileTreeEntry>();
            foreach (string path in Directory.EnumerateDirectories(directoryPath))
            {
                if (IsCancelled(requestId)) return result;
                if (directories.Count + files.Count >= result.Limit)
                {
                    result.IsTruncated = true;
                    break;
                }
                directories.Add(new WorkflowFileTreeEntry { Name = GetEntryName(path), FullPath = path, IsDirectory = true });
            }
            if (!result.IsTruncated)
            {
                foreach (string path in Directory.EnumerateFiles(directoryPath))
                {
                    if (IsCancelled(requestId)) return result;
                    if (directories.Count + files.Count >= result.Limit)
                    {
                        result.IsTruncated = true;
                        break;
                    }
                    files.Add(new WorkflowFileTreeEntry { Name = GetEntryName(path), FullPath = path, IsDirectory = false });
                }
            }
            directories.Sort(delegate(WorkflowFileTreeEntry left, WorkflowFileTreeEntry right) { return StringComparer.CurrentCultureIgnoreCase.Compare(left.Name, right.Name); });
            files.Sort(delegate(WorkflowFileTreeEntry left, WorkflowFileTreeEntry right) { return StringComparer.CurrentCultureIgnoreCase.Compare(left.Name, right.Name); });
            result.Entries.AddRange(directories);
            result.Entries.AddRange(files);
        }
        catch (UnauthorizedAccessException ex) { result.Error = ex.Message; }
        catch (IOException ex) { result.Error = ex.Message; }
        catch (Exception ex) { result.Error = ex.Message; }
        return result;
    }

    public static void Queue(Control dispatcher, string directoryPath, int limit, string requestId, Action<WorkflowFileTreeResult> callback)
    {
        if (dispatcher == null || callback == null) return;
        string safeRequestId = requestId ?? "";
        if (String.IsNullOrWhiteSpace(safeRequestId)) safeRequestId = Guid.NewGuid().ToString("N");
        byte ignored;
        CancelledRequests.TryRemove(safeRequestId, out ignored);
        ActiveRequests[safeRequestId] = 0;
        ThreadPool.QueueUserWorkItem(delegate
        {
            bool posted = false;
            try
            {
                WorkflowFileTreeResult result = Enumerate(directoryPath, limit, safeRequestId);
                if (!ActiveRequests.ContainsKey(safeRequestId) || dispatcher.IsDisposed || !dispatcher.IsHandleCreated) return;
                dispatcher.BeginInvoke((Action)(delegate
                {
                    try
                    {
                        if (ActiveRequests.ContainsKey(safeRequestId) && !dispatcher.IsDisposed) callback(result);
                    }
                    catch (Exception) { }
                    finally
                    {
                        byte ignoredCallback;
                        ActiveRequests.TryRemove(safeRequestId, out ignoredCallback);
                        CancelledRequests.TryRemove(safeRequestId, out ignoredCallback);
                    }
                }));
                posted = true;
            }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { }
            finally
            {
                if (!posted)
                {
                    byte ignoredCleanup;
                    ActiveRequests.TryRemove(safeRequestId, out ignoredCleanup);
                    CancelledRequests.TryRemove(safeRequestId, out ignoredCleanup);
                }
            }
        });
    }
}

public sealed class WorkflowProcessStreamCapture : IDisposable
{
    private readonly StreamReader reader;
    private readonly int maximumCharacters;
    private readonly int prefixLimit;
    private readonly int suffixLimit;
    private readonly object gate = new object();
    private StringBuilder full = new StringBuilder();
    private readonly StringBuilder prefix = new StringBuilder();
    private readonly StringBuilder suffix = new StringBuilder();
    private bool truncated;
    private bool disposed;
    private Task completionTask;

    public string Error { get; private set; }
    public Task CompletionTask { get { return completionTask; } }

    public WorkflowProcessStreamCapture(StreamReader source, int maxCharacters)
    {
        reader = source;
        maximumCharacters = Math.Max(4096, maxCharacters);
        prefixLimit = Math.Max(2048, maximumCharacters / 2);
        suffixLimit = Math.Max(2048, maximumCharacters - prefixLimit);
        completionTask = Task.Factory.StartNew(new Action(ReadLoop), CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    private void AppendTail(char[] buffer, int offset, int count)
    {
        if (count <= 0) return;
        if (count >= suffixLimit)
        {
            suffix.Clear();
            suffix.Append(buffer, offset + count - suffixLimit, suffixLimit);
            return;
        }
        int overflow = suffix.Length + count - suffixLimit;
        if (overflow > 0) suffix.Remove(0, Math.Min(overflow, suffix.Length));
        suffix.Append(buffer, offset, count);
    }

    private void AppendChunk(char[] buffer, int count)
    {
        lock (gate)
        {
            if (!truncated && full.Length + count <= maximumCharacters)
            {
                full.Append(buffer, 0, count);
                return;
            }
            if (!truncated)
            {
                string existing = full.ToString();
                int prefixCount = Math.Min(prefixLimit, existing.Length);
                if (prefixCount > 0) prefix.Append(existing, 0, prefixCount);
                int suffixStart = Math.Max(0, existing.Length - suffixLimit);
                if (existing.Length > suffixStart) suffix.Append(existing, suffixStart, existing.Length - suffixStart);
                full = null;
                truncated = true;
            }
            int prefixNeed = prefixLimit - prefix.Length;
            if (prefixNeed > 0) prefix.Append(buffer, 0, Math.Min(prefixNeed, count));
            AppendTail(buffer, 0, count);
        }
    }

    private void ReadLoop()
    {
        try
        {
            char[] buffer = new char[8192];
            int read;
            while ((read = reader.Read(buffer, 0, buffer.Length)) > 0) AppendChunk(buffer, read);
        }
        catch (ObjectDisposedException) { }
        catch (Exception ex) { Error = ex.Message; }
        finally { try { reader.Dispose(); } catch { } }
    }

    public bool IsCompleted { get { return completionTask != null && completionTask.IsCompleted; } }

    public string GetText()
    {
        lock (gate)
        {
            if (!truncated) return full == null ? "" : full.ToString();
            return prefix.ToString() + "\r\n[输出过长，已裁剪中间内容]\r\n" + suffix.ToString();
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
        }
        try { reader.Dispose(); } catch { }
    }
}

public sealed class WorkflowApiRequest : IDisposable
{
    public string ServerName { get; set; }
    public Guid Id { get; private set; }
    public string Method { get; set; }
    public string Target { get; set; }
    public string Body { get; set; }
    public Dictionary<string, string> Headers { get; private set; }
    public ManualResetEventSlim Completed { get; private set; }
    public int ResponseStatusCode { get; set; }
    public string ResponseContentType { get; set; }
    public string ResponseBody { get; set; }

    public WorkflowApiRequest()
    {
        Id = Guid.NewGuid();
        Method = "GET";
        Target = "/";
        Body = "";
        Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        Completed = new ManualResetEventSlim(false);
        ResponseStatusCode = 500;
        ResponseContentType = "application/json; charset=utf-8";
        ResponseBody = "{\"ok\":false,\"error\":{\"code\":\"internal_error\",\"message\":\"Request was not completed.\"}}";
    }

    public void Dispose()
    {
        Completed.Dispose();
    }
}

public sealed class WorkflowApiServer : IDisposable
{
    private const int MaxHeaderBytes = 65536;
    private const int MaxBodyBytes = 4 * 1024 * 1024;
    private readonly ConcurrentQueue<WorkflowApiRequest> requests = new ConcurrentQueue<WorkflowApiRequest>();
    private TcpListener listener;
    private Thread acceptThread;
    private volatile bool running;

    public int Port { get; private set; }
    public string BindAddress { get; private set; }
    public string ServerName { get; set; }

    public void Start(int port)
    {
        Start(IPAddress.Loopback, port);
    }

    public void Start(string bindAddress, int port)
    {
        Start(IPAddress.Parse(bindAddress), port);
    }

    private void Start(IPAddress address, int port)
    {
        if (running) return;
        listener = new TcpListener(address, port);
        try { listener.Server.ExclusiveAddressUse = true; } catch { }
        listener.Start(20);
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        BindAddress = address.ToString();
        if (String.IsNullOrWhiteSpace(ServerName)) ServerName = new String(new char[] {'l','o','c','a','l'});
        running = true;
        acceptThread = new Thread(AcceptLoop);
        acceptThread.IsBackground = true;
        acceptThread.Name = "Shijia Workflow API";
        acceptThread.Start();
    }

    public bool TryDequeue(out WorkflowApiRequest request)
    {
        return requests.TryDequeue(out request);
    }

    private void AcceptLoop()
    {
        while (running)
        {
            try
            {
                TcpClient client = listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(HandleClient, client);
            }
            catch (SocketException) { if (running) Thread.Sleep(50); }
            catch (ObjectDisposedException) { }
        }
    }

    private static byte[] ReadHeader(NetworkStream stream)
    {
        using (MemoryStream buffer = new MemoryStream())
        {
            int state = 0;
            while (buffer.Length < MaxHeaderBytes)
            {
                int value = stream.ReadByte();
                if (value < 0) throw new EndOfStreamException("Connection closed before request headers completed.");
                buffer.WriteByte((byte)value);
                if ((state == 0 || state == 2) && value == 13) state++;
                else if ((state == 1 || state == 3) && value == 10) state++;
                else state = value == 13 ? 1 : 0;
                if (state == 4) return buffer.ToArray();
            }
        }
        throw new InvalidDataException("Request headers are too large.");
    }

    private static byte[] ReadBody(NetworkStream stream, int length)
    {
        if (length < 0 || length > MaxBodyBytes) throw new InvalidDataException("Request body is too large.");
        byte[] body = new byte[length];
        int offset = 0;
        while (offset < length)
        {
            int read = stream.Read(body, offset, length - offset);
            if (read <= 0) throw new EndOfStreamException("Connection closed before request body completed.");
            offset += read;
        }
        return body;
    }

    private void HandleClient(object state)
    {
        using (TcpClient client = (TcpClient)state)
        {
            client.ReceiveTimeout = 10000;
            client.SendTimeout = 35000;
            try
            {
                using (NetworkStream stream = client.GetStream())
                {
                    string headerText = Encoding.ASCII.GetString(ReadHeader(stream));
                    string[] lines = headerText.Split(new[] { "\r\n" }, StringSplitOptions.None);
                    string[] requestLine = lines[0].Split(new[] { ' ' }, 3);
                    if (requestLine.Length < 2) throw new InvalidDataException("Invalid HTTP request line.");

                    WorkflowApiRequest request = new WorkflowApiRequest();
                    request.Method = requestLine[0].ToUpperInvariant();
                    request.Target = requestLine[1];
                    int contentLength = 0;
                    for (int index = 1; index < lines.Length; index++)
                    {
                        int separator = lines[index].IndexOf(':');
                        if (separator <= 0) continue;
                        string name = lines[index].Substring(0, separator).Trim();
                        string value = lines[index].Substring(separator + 1).Trim();
                        request.Headers[name] = value;
                        if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) int.TryParse(value, out contentLength);
                    }
                    if (contentLength > 0) request.Body = Encoding.UTF8.GetString(ReadBody(stream, contentLength));
                    request.ServerName = ServerName;
                    requests.Enqueue(request);

                    if (!request.Completed.Wait(30000))
                    {
                        request.ResponseStatusCode = 503;
                        request.ResponseBody = "{\"ok\":false,\"error\":{\"code\":\"timeout\",\"message\":\"WorkflowManager did not process the request in time.\"}}";
                    }
                    WriteResponse(stream, request.ResponseStatusCode, request.ResponseContentType, request.ResponseBody);
                    request.Dispose();
                }
            }
            catch (Exception exception)
            {
                try
                {
                    using (NetworkStream stream = client.GetStream())
                    {
                        string message = exception.Message.Replace("\\", "\\\\").Replace("\"", "\\\"");
                        WriteResponse(stream, 400, "application/json; charset=utf-8", "{\"ok\":false,\"error\":{\"code\":\"bad_request\",\"message\":\"" + message + "\"}}");
                    }
                }
                catch { }
            }
        }
    }

    private static string ReasonPhrase(int statusCode)
    {
        switch (statusCode)
        {
            case 200: return "OK";
            case 201: return "Created";
            case 204: return "No Content";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 409: return "Conflict";
            case 413: return "Payload Too Large";
            case 500: return "Internal Server Error";
            case 503: return "Service Unavailable";
            default: return "HTTP Response";
        }
    }

    private static void WriteResponse(NetworkStream stream, int statusCode, string contentType, string body)
    {
        if (body == null) body = "";
        byte[] bodyBytes = Encoding.UTF8.GetBytes(body);
        string headers = "HTTP/1.1 " + statusCode + " " + ReasonPhrase(statusCode) + "\r\n" +
            "Content-Type: " + contentType + "\r\n" +
            "Content-Length: " + bodyBytes.Length + "\r\n" +
            "Connection: close\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n\r\n";
        byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
        stream.Write(headerBytes, 0, headerBytes.Length);
        if (bodyBytes.Length > 0) stream.Write(bodyBytes, 0, bodyBytes.Length);
        stream.Flush();
    }

    public void Stop()
    {
        running = false;
        try { if (listener != null) listener.Stop(); } catch { }
        if (acceptThread != null && acceptThread.IsAlive) acceptThread.Join(1000);
        listener = null;
        acceptThread = null;
        Port = 0;
        BindAddress = "";
        WorkflowApiRequest pending;
        while (requests.TryDequeue(out pending))
        {
            pending.ResponseStatusCode = 503;
            pending.ResponseBody = "{\"ok\":false,\"error\":{\"code\":\"stopping\",\"message\":\"WorkflowManager is stopping.\"}}";
            pending.Completed.Set();
        }
    }

    public void Dispose()
    {
        Stop();
    }
}
'@

$script:AppName = '使驾'
$script:DataDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PowerUI\WorkflowManager'
$script:WorkflowPath = Join-Path $script:DataDirectory 'workflows.json'
$script:ProjectPath = Join-Path $script:DataDirectory 'projects.json'
$script:SettingsPath = Join-Path $script:DataDirectory 'settings.json'
$script:ApplicationDirectory = [string]$PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ApplicationDirectory)) {
    try { $script:ApplicationDirectory = [IO.Path]::GetDirectoryName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
}
if ([string]::IsNullOrWhiteSpace($script:ApplicationDirectory)) { $script:ApplicationDirectory = [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) }
$script:WorkflowAiDirectory = Join-Path $script:ApplicationDirectory 'workflow-ai'
$script:EmbeddedWorkflowSkillPath = Join-Path $script:WorkflowAiDirectory 'skills\workflow-manager'
$script:SourceWorkflowSkillPath = Join-Path $script:ApplicationDirectory 'skill\workflow-manager'
$script:ExamplesMarkerPath = Join-Path $script:DataDirectory 'examples-v3.installed'
$script:LogDirectory = Join-Path $script:DataDirectory 'logs'
$script:LogPath = Join-Path $script:LogDirectory ((Get-Date).ToString('yyyyMMdd') + '.log')
$script:CodexSessionsDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\sessions'
$script:ApiPort = 5169
$script:ApiServer = $null
$script:WebApiServer = $null
$script:WebApiSessions = @{}
$script:WebApiSessionTimeoutMinutes = 720
$script:WebApiPort = 5170
$script:CodexSessionCache = @()
$script:CodexSessionCacheAt = [datetime]::MinValue
$script:Workflows = @()
$script:Projects = @()
$script:GlobalSettings = $null
$script:CurrentWorkflow = $null
$script:CurrentProject = $null
$script:MainForm = $null
$script:WorkflowList = $null
$script:WorkflowListContextMenu = $null
$script:CopiedWorkflowJson = ''
$script:ProjectSelector = $null
$script:ProjectSelectorFrame = $null
$script:ProjectSelectorRefreshActive = $false
$script:ProjectInfoLabel = $null
$script:ProjectSessionLabel = $null
$script:ProjectEditButton = $null
$script:ProjectDeleteButton = $null
$script:ProjectOpenButton = $null
$script:ProjectVSCodeButton = $null
$script:ProjectChatButton = $null
$script:ProjectTerminalButton = $null
$script:ProjectConversationMenu = $null
$script:ProjectToolTip = $null
$script:Canvas = $null
$script:WorkflowSettingsPanel = $null
$script:WorkflowLogPanel = $null
$script:CodexConversationPanel = $null
$script:CodexConversationSplit = $null
$script:CodexConversationLayout = $null
$script:CodexConversationHeader = $null
$script:CodexConversationComposer = $null
$script:CodexConversationComposerLayout = $null
$script:CodexConversationComposerLayoutHandler = $null
$script:CodexConversationActions = $null
$script:CodexConversationComposerResizeGrip = $null
$script:CodexConversationComposerExpandButton = $null
$script:CodexConversationComposerUserHeight = 0
$script:CodexConversationComposerExpanded = $false
$script:CodexConversationComposerRestoreHeight = 0
$script:CodexConversationComposerDragActive = $false
$script:CodexConversationComposerDragStartY = 0
$script:CodexConversationComposerDragStartHeight = 0
$script:CodexConversationAttachmentPreview = $null
$script:CodexConversationAttachButton = $null
$script:CodexConversationClearAttachmentsButton = $null
$script:CodexConversationPendingImages = New-Object System.Collections.ArrayList
$script:CodexConversationComposerRowStyle = $null
$script:CodexConversationOutputHost = $null
$script:CodexConversationOutput = $null
$script:CodexConversationInputFrame = $null
$script:CodexConversationInputSurface = $null
$script:CodexConversationInput = $null
$script:CodexConversationTitle = $null
$script:CodexConversationMeta = $null
$script:CodexConversationSessionSelector = $null
$script:CodexConversationSessionSelectorBinding = $false
$script:CodexConversationSessionSelectorRefreshActive = $false
$script:CodexConversationSessionSelectorSwitchPending = $false
$script:CodexConversationStatus = $null
$script:CodexConversationSend = $null
$script:CodexConversationStopButton = $null
$script:CodexConversationTerminalButton = $null
$script:CodexConversationReloadButton = $null
$script:CodexConversationPreviousUserButton = $null
$script:CodexConversationSearchLabel = $null
$script:CodexConversationSearchFrame = $null
$script:CodexConversationSearchBox = $null
$script:CodexConversationSearchQuery = ''
$script:CodexConversationSearchMatches = @()
$script:CodexConversationSearchIndex = -1
$script:CodexConversationSearchSignature = ''
$script:CodexConversationSearchSelectedRecord = $null
$script:CodexConversationHeaderLayoutInProgress = $false
$script:CodexConversationSurfaceRefreshPending = $false
$script:CodexConversationSurfaceForcePending = $false
$script:CodexConversationSurfaceRefreshCallback = $null
$script:CodexConversationBackButton = $null
$script:CodexConversationFileTreeToggleButton = $null
$script:CodexConversationFileTreePanel = $null
$script:CodexConversationFileTreeHeader = $null
$script:CodexConversationFileTreeHost = $null
$script:CodexConversationFileTree = $null
$script:CodexConversationFileTreePathLabel = $null
$script:CodexConversationFileTreeRefreshButton = $null
$script:CodexConversationFileTreeCollapseButton = $null
$script:CodexConversationFileTreeContextMenu = $null
$script:CodexConversationFileTreeToolTip = $null
$script:CodexConversationFileTreeRequestIds = @{}
$script:CodexConversationFileTreeRequestContexts = @{}
$script:CodexConversationFileTreeCallback = $null
$script:CodexConversationFileTreeRootFont = $null
$script:CodexConversationFileTreeDirectory = ''
$script:CodexConversationFileTreeUserVisible = $true
$script:CodexConversationTimer = $null
$script:CodexConversationProcess = $null
$script:CodexConversationProcesses = @{}
$script:CodexConversationOutputDrainTimeoutSeconds = 5
$script:CodexConversationLastPollError = ''
$script:CodexConversationLastPollErrorAt = [datetime]::MinValue
$script:CodexConversationSnapshots = @{}
$script:CodexConversationSnapshotAccess = @{}
$script:CodexConversationSnapshotMaxCount = 24
$script:CodexConversationSnapshotMaxCharacters = 32000000
$script:CodexConversationSnapshotMaxCharactersPerSession = 4000000
$script:CodexConversationSnapshotMaxMessageCharacters = 2000000
$script:CodexConversationSnapshotMaxMessages = 120
$script:CodexConversationLastAutoRefreshAt = [datetime]::MinValue
$script:CodexConversationProjectId = ''
$script:CodexConversationSessionId = ''
$script:CodexConversationSessionDescription = '无描述'
$script:CodexConversationSessionModel = ''
$script:CodexConversationHistory = @{}
$script:CodexConversationHistoryAccess = @{}
$script:CodexConversationHistoryMaxCount = 12
$script:CodexConversationHistoryMaxCharacters = 8000000
$script:CodexConversationHistoryMaxEntryCharacters = 1500000
$script:CodexConversationUserMessagePositions = New-Object System.Collections.ArrayList
$script:CodexConversationUserNavigationIndex = 0
$script:CodexConversationLinks = New-Object System.Collections.ArrayList
$script:CodexConversationLinkContextMenu = $null
$script:CodexConversationLinkContext = $null
$script:CodexConversationLastRole = ''
$script:CodexConversationActiveBackColor = [Drawing.Color]::FromArgb(248, 250, 252)
$script:CodexConversationRenderBox = $null
$script:CodexConversationCurrentLinks = $null
$script:CodexConversationCurrentBubble = $null
$script:CodexConversationBubbleRecords = New-Object System.Collections.ArrayList
$script:CodexConversationTranscriptParts = New-Object System.Collections.ArrayList
$script:CodexConversationBatchRendering = $false
$script:CodexConversationBottomSpacer = $null
$script:CodexConversationResizeInProgress = $false
$script:CodexConversationOutputLayoutWidth = 0
$script:CodexConversationOutputLayoutDpi = 0
$script:CodexConversationScrollPending = $false
$script:CodexConversationScrollGeneration = 0
$script:CodexConversationMouseWheelScrollPending = $false
$script:CodexConversationMouseWheelTargetY = 0
$script:CodexConversationMouseWheelCallback = $null
$script:CodexConversationBottomScrollGeneration = 0
$script:CodexConversationBottomScrollCallback = $null
$script:CodexConversationRecordScrollPending = $false
$script:CodexConversationRecordScrollTargetY = 0
$script:CodexConversationRecordScrollRecord = $null
$script:CodexConversationRecordScrollPreserveFocus = $true
$script:CodexConversationRecordScrollCallback = $null
$script:CodexConversationSessionSwitchSender = $null
$script:CodexConversationSessionSwitchCallback = $null
$script:CodexConversationSnapshotNoChangeHits = [long]0
$script:CodexConversationSnapshotRebuilds = [long]0
$script:CodexConversationAutomaticRefreshes = [long]0
$script:CodexConversationMode = 'Project'
$script:WorkflowAiConversationHistory = ''
$script:WorkflowAiSkillPath = ''
$script:LogBox = $null
$script:WorkflowNameBox = $null
$script:WorkflowNameFrame = $null
$script:WorkflowEnabled = $null
$script:IntervalBox = $null
$script:ScheduleModeBox = $null
$script:ScheduleKindBox = $null
$script:ScheduleTimeBox = $null
$script:ScheduleWeekdaysBox = $null
$script:ScheduleDayBox = $null
$script:IntervalLabel = $null
$script:ScheduleTimeLabel = $null
$script:ScheduleWeekdaysLabel = $null
$script:ScheduleDayLabel = $null
$script:NextRunLabel = $null
$script:StatusLabel = $null
$script:CommandPanel = $null
$script:WorkflowHeaderBrand = $null
$script:WorkflowActionsPanel = $null
$script:ScheduleButton = $null
$script:RunningTasksButton = $null
$script:CommonPromptsButton = $null
$script:SessionManagerButton = $null
$script:SessionManagerPanel = $null
$script:SessionManagerGrid = $null
$script:SessionManagerOpenButton = $null
$script:SessionManagerRefreshButton = $null
$script:SessionManagerLastRefreshAt = [datetime]::MinValue
$script:SessionManagerRefreshActive = $false
$script:SessionManagerStateReuseHits = 0L
$script:SessionManagerStateBuilds = 0L
$script:RunningTaskBackButton = $null
$script:RunningTasksPanel = $null
$script:RunningTasksGrid = $null
$script:RunningTaskTitle = $null
$script:RunningTaskMeta = $null
$script:RunningTaskLogBox = $null
$script:RunningTaskStopButton = $null
$script:RunningTaskDisplayedId = ''
$script:RunningTaskDisplayedLogCount = 0
$script:RunningTaskLogNeedsReset = $false
$script:GlobalLogVisibleLineCount = 0
$script:CommonPromptList = $null
$script:CommonPromptsPanel = $null
$script:CommonPromptsForm = $null
$script:CommonPromptsHost = $null
$script:CommonPromptsHeader = $null
$script:CommonPromptsDescriptionLabel = $null
$script:CommonPromptBackButton = $null
$script:CommonPromptAddButton = $null
$script:CommonPromptEditButton = $null
$script:CommonPromptDeleteButton = $null
$script:CommonPromptCopyButton = $null
$script:NotifyIcon = $null
$script:ApplicationIcon = $null
$script:SmallApplicationIcon = $null
$script:TrayIcon = $null
$script:TrayIconSize = 0
$script:ApplicationContext = $null
$script:TrayMenu = $null
$script:TrayOpenItem = $null
$script:TrayRunItem = $null
$script:TrayRunAllItem = $null
$script:TrayExitItem = $null
$script:SingleInstanceCoordinator = $null
$script:SchedulerTimer = $null
$script:JobPollTimer = $null
$script:MemoryMaintenanceTimer = $null
$script:LastMemoryMaintenanceAt = [datetime]::MinValue
$script:ApiTimer = $null
$script:StartupTimer = $null
$script:RunningJobs = @{}
$script:PendingWorkflowRestarts = @{}
$script:PendingBalloonAction = $null
$script:AllowExit = $false
$script:Exiting = $false
$script:BindingWorkflow = $false
$script:SelectedNode = $null
$script:SelectedEdge = $null
$script:DraggingNode = $null
$script:DragOffset = $null
$script:ConnectingFrom = $null
$script:ConnectPoint = $null
$script:CanvasInlineVariableLastKey = ''
$script:CanvasInlineVariableLastAt = [datetime]::MinValue
$script:CanvasRenderError = $null
$script:CopiedCanvasNodeJson = ''
$script:CanvasContextPoint = $null
$script:CanvasContextMenu = $null
$script:WorkerScript = @'
param(
    [string]$WorkflowJson,
    [string]$InputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not [string]::IsNullOrWhiteSpace($InputPath)) { $WorkflowJson = [IO.File]::ReadAllText($InputPath, [Text.Encoding]::UTF8) }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$null = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$workflow = $WorkflowJson | ConvertFrom-Json
$context = [pscustomobject]@{
    Env = @{}
    Vars = @{}
    Control = @{}
    Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    ExecutionCount = 0
}

function Write-Event {
    param([string]$Kind, [string]$Message, [hashtable]$Data = @{})
    [pscustomobject]@{ Kind = $Kind; Message = $Message; Data = $Data; At = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 8 -Compress
}

function Limit-WorkerEventMessage {
    param([AllowNull()][string]$Message, [int]$MaximumCharacters = 65536)
    if ($null -eq $Message) { return '' }
    if ($Message.Length -le $MaximumCharacters) { return $Message }
    $marker = [Environment]::NewLine + '[output line truncated]'
    $keep = [Math]::Max(0, $MaximumCharacters - $marker.Length)
    return $Message.Substring(0, [Math]::Min($keep, $Message.Length)) + $marker
}

function Append-BoundedWorkerOutput {
    param([Text.StringBuilder]$Builder, [AllowNull()][string]$Line, [int]$MaximumCharacters)
    if ($null -eq $Line -or $MaximumCharacters -lt 1 -or $Builder.Length -ge $MaximumCharacters) { return }
    $text = $Line + [Environment]::NewLine
    $remaining = $MaximumCharacters - $Builder.Length
    if ($text.Length -le $remaining) { [void]$Builder.Append($text); return }
    $marker = '...' + [Environment]::NewLine + '[output truncated]'
    if ($remaining -gt $marker.Length) {
        [void]$Builder.Append($text.Substring(0, $remaining - $marker.Length))
        [void]$Builder.Append($marker)
    } else { [void]$Builder.Append($text.Substring(0, $remaining)) }
}

function Stop-ChildProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    try {
        $taskKillPath = Join-Path $env:WINDIR 'System32\taskkill.exe'
        $killInfo = New-Object Diagnostics.ProcessStartInfo
        $killInfo.FileName = $taskKillPath
        $killInfo.Arguments = '/PID ' + $ProcessId + ' /T /F'
        $killInfo.UseShellExecute = $false
        $killInfo.CreateNoWindow = $true
        $killInfo.RedirectStandardOutput = $true
        $killInfo.RedirectStandardError = $true
        $killProcess = [Diagnostics.Process]::Start($killInfo)
        if ($null -ne $killProcess) { [void]$killProcess.WaitForExit(5000); $killProcess.Dispose() }
    } catch {
        try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Resolve-PathValue {
    param($Value, [string]$Path)
    $current = $Value
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary] -and $current.Contains($part)) { $current = $current[$part] }
        else {
            $property = $current.PSObject.Properties[$part]
            if ($null -ne $property) { $current = $property.Value }
            else { return $null }
        }
    }
    return $current
}

function ConvertTo-CmdBatchDataValue {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('%', '%%')
}

function Protect-CmdBatchUrlEncoding {
    param([AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrEmpty($Command)) { return '' }
    return [regex]::Replace($Command, '(?i)\b(?:https?|ftp)://[^\s"''<>]+', {
        param($urlMatch)
        return [regex]::Replace($urlMatch.Value, '(?<!%)%([0-9a-f]{2})', '%%$1', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    })
}

function Resolve-Template {
    param([string]$Text, [switch]$EscapeCmdBatchValues)
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, '\{\{([^}]+)\}\}', {
        param($match)
        $token = $match.Groups[1].Value.Trim()
        if ($token -like 'env.*') {
            $name = $token.Substring(4)
            if ($context.Env.ContainsKey($name)) {
                $resolved = [string]$context.Env[$name]
                if ($EscapeCmdBatchValues) { return ConvertTo-CmdBatchDataValue $resolved }
                return $resolved
            }
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($null -eq $value) { throw "环境变量不存在：$name" }
            $resolved = [string]$value
            if ($EscapeCmdBatchValues) { return ConvertTo-CmdBatchDataValue $resolved }
            return $resolved
        }
        if ($token -like 'var.*') {
            $value = Resolve-PathValue $context.Vars $token.Substring(4)
            if ($null -eq $value) { throw "工作流变量不存在：$($token.Substring(4))" }
            $resolved = if ($value -is [string]) { $value } else { $value | ConvertTo-Json -Depth 8 -Compress }
            if ($EscapeCmdBatchValues) { return ConvertTo-CmdBatchDataValue ([string]$resolved) }
            return [string]$resolved
        }
        if ($token -like 'date:*') { return (Get-Date).ToString($token.Substring(5)) }
        return $match.Value
    })
}

function Convert-Headers {
    param([string]$Json)
    $headers = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) { return $headers }
    $object = $Json | ConvertFrom-Json
    foreach ($property in $object.PSObject.Properties) { $headers[$property.Name] = Resolve-Template ([string]$property.Value) }
    return $headers
}

function Get-ConfigValue {
    param($Config, [string]$Name, $Default = $null)
    if ($null -eq $Config) { return $Default }
    if ($Config -is [System.Collections.IDictionary] -and $Config.Contains($Name)) { return $Config[$Name] }
    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-ConfigValue {
    param($Config, [string]$Name)
    if ($null -eq $Config) { return $false }
    if ($Config -is [System.Collections.IDictionary]) { return $Config.Contains($Name) }
    return $null -ne $Config.PSObject.Properties[$Name]
}

function Get-TaskEnvironmentValue {
    param([string]$Name)
    if ($context.Env.ContainsKey($Name)) { return $context.Env[$Name] }
    return [Environment]::GetEnvironmentVariable($Name, 'Process')
}

function ConvertTo-TaskString {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return Resolve-Template $Value }
    return Resolve-Template ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function ConvertFrom-BatchJson {
    param([string]$Json, [string]$NodeName)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw "$NodeName：批量 JSON 不能为空。" }
    try { $object = $Json | ConvertFrom-Json } catch { throw "$NodeName：批量 JSON 格式错误：$($_.Exception.Message)" }
    $properties = @($object.PSObject.Properties)
    if ($properties.Count -eq 0) { throw "$NodeName：批量 JSON 至少需要一个属性。" }
    return $properties
}

function ConvertTo-EnvironmentRows {
    param($ItemsValue, [switch]$Read)
    $rows = New-Object System.Collections.ArrayList
    $rightName = if ($Read) { 'Variable' } else { 'Value' }
    foreach ($item in @($ItemsValue)) {
        if ($null -eq $item) { continue }
        if (Test-ConfigValue $item 'Name') {
            $name = [string](Get-ConfigValue $item 'Name' '')
            $right = Get-ConfigValue $item $rightName ''
            if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = $name; Variable = [string]$right }) }
            else { [void]$rows.Add([pscustomobject]@{ Name = $name; Value = $right; ValueType = [string](Get-ConfigValue $item 'ValueType' 'String') }) }
            continue
        }
        if (Test-ConfigValue $item 'Key') {
            $name = [string](Get-ConfigValue $item 'Key' '')
            $right = Get-ConfigValue $item 'Value' ''
            if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = $name; Variable = [string]$right }) }
            else { [void]$rows.Add([pscustomobject]@{ Name = $name; Value = $right }) }
            continue
        }
        if (Test-ConfigValue $item $rightName) {
            $right = Get-ConfigValue $item $rightName ''
            if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = ''; Variable = [string]$right }) }
            else { [void]$rows.Add([pscustomobject]@{ Name = ''; Value = $right }) }
            continue
        }
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($key in @($item.Keys)) {
                if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = [string]$key; Variable = [string]$item[$key] }) }
                else { [void]$rows.Add([pscustomobject]@{ Name = [string]$key; Value = $item[$key] }) }
            }
            continue
        }
        $mapProperties = @($item.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
        if ($mapProperties.Count -gt 0) {
            foreach ($property in $mapProperties) {
                if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = [string]$property.Name; Variable = [string]$property.Value }) }
                else { [void]$rows.Add([pscustomobject]@{ Name = [string]$property.Name; Value = $property.Value }) }
            }
            continue
        }
        if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = [string]$item; Variable = '' }) }
        else { [void]$rows.Add([pscustomobject]@{ Name = [string]$item; Value = '' }) }
    }
    return @($rows)
}

function Get-EnvironmentItems {
    param($Config, [switch]$Read)
    $itemsValue = Get-ConfigValue $Config 'Items' $null
    if ($null -ne $itemsValue -and @($itemsValue).Count -gt 0) { return @(ConvertTo-EnvironmentRows $itemsValue -Read:$Read) }
    $mode = [string](Get-ConfigValue $Config 'Mode' 'Single')
    $items = @()
    if ($mode -eq 'Json') {
        $properties = ConvertFrom-BatchJson ([string](Get-ConfigValue $Config 'Json' '')) '环境变量节点'
        foreach ($property in $properties) {
            if ($Read) { $items += [pscustomobject]@{ Name = [string]$property.Name; Variable = [string]$property.Value } }
            else { $items += [pscustomobject]@{ Name = [string]$property.Name; Value = $property.Value } }
        }
        return $items
    }
    $name = [string](Get-ConfigValue $Config 'Name' '')
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        if ($Read) { $items += [pscustomobject]@{ Name = $name; Variable = [string](Get-ConfigValue $Config 'Variable' '') } }
        else { $items += [pscustomobject]@{ Name = $name; Value = Get-ConfigValue $Config 'Value' '' } }
    }
    return $items
}

function ConvertTo-WorkflowValue {
    param($RawValue, [string]$ValueType, [string]$NodeName)
    $text = ConvertTo-TaskString $RawValue
    switch ($ValueType) {
        'Json' {
            try { return ($text | ConvertFrom-Json) }
            catch { throw "$NodeName：JSON 值格式错误：$($_.Exception.Message)" }
        }
        'Number' {
            $number = 0D
            if ([decimal]::TryParse($text, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
            if ([decimal]::TryParse($text, [ref]$number)) { return $number }
            throw "$NodeName：无法将 '$text' 转换为数字。"
        }
        'Boolean' {
            switch ($text.Trim().ToLowerInvariant()) {
                { $_ -in @('true','1','yes','on','是') } { return $true }
                { $_ -in @('false','0','no','off','否') } { return $false }
                default { throw "$NodeName：无法将 '$text' 转换为布尔值。" }
            }
        }
        default { return [string]$text }
    }
}

function Set-WorkflowVariable {
    param([string]$Name, $Value)
    $context.Vars[$Name] = $Value
    if ($Value -is [string]) { $context.Env[$Name] = $Value }
    elseif ($null -eq $Value) { $context.Env[$Name] = '' }
    else { $context.Env[$Name] = ($Value | ConvertTo-Json -Depth 20 -Compress) }
}

function Test-WorkflowCondition {
    param($Node)
    $left = Resolve-Template ([string](Get-ConfigValue $Node.Config 'Left' ''))
    $right = Resolve-Template ([string](Get-ConfigValue $Node.Config 'Right' ''))
    $operator = [string](Get-ConfigValue $Node.Config 'Operator' 'Equals')
    $leftNumber = 0D; $rightNumber = 0D
    $numbers = [decimal]::TryParse($left, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$leftNumber) -and [decimal]::TryParse($right, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$rightNumber)
    switch ($operator) {
        'NotEquals' { return -not [string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase) }
        'Contains' { return $left.IndexOf($right, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        'NotContains' { return $left.IndexOf($right, [StringComparison]::OrdinalIgnoreCase) -lt 0 }
        'GreaterThan' { if ($numbers) { return $leftNumber -gt $rightNumber }; return [string]::Compare($left, $right, $true) -gt 0 }
        'GreaterOrEqual' { if ($numbers) { return $leftNumber -ge $rightNumber }; return [string]::Compare($left, $right, $true) -ge 0 }
        'LessThan' { if ($numbers) { return $leftNumber -lt $rightNumber }; return [string]::Compare($left, $right, $true) -lt 0 }
        'LessOrEqual' { if ($numbers) { return $leftNumber -le $rightNumber }; return [string]::Compare($left, $right, $true) -le 0 }
        'IsEmpty' { return [string]::IsNullOrWhiteSpace($left) }
        'NotEmpty' { return -not [string]::IsNullOrWhiteSpace($left) }
        'Matches' { try { return [regex]::IsMatch($left, $right) } catch { throw "$($Node.Name)：正则表达式无效：$($_.Exception.Message)" } }
        default { return [string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase) }
    }
}

function Get-WorkflowLoopItems {
    param($Node)
    $source = Resolve-Template ([string](Get-ConfigValue $Node.Config 'Items' '[]'))
    if ([string]::IsNullOrWhiteSpace($source)) { return @() }
    try {
        $parsed = $source | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        if ($parsed -is [string]) { return @($parsed) }
        if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [System.Collections.IDictionary] -and $parsed -isnot [pscustomobject]) { return @($parsed) }
        return @($parsed)
    } catch {
        return @($source -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Invoke-CmdNode {
    param($Node)
    $command = Resolve-Template ([string](Get-ConfigValue $Node.Config 'Command' '')) -EscapeCmdBatchValues
    $command = Protect-CmdBatchUrlEncoding $command
    if ([string]::IsNullOrWhiteSpace($command)) { throw "$($Node.Name)：命令内容不能为空。" }
    $workingDirectory = Resolve-Template ([string](Get-ConfigValue $Node.Config 'WorkingDirectory' ''))
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) { $workingDirectory = [Environment]::CurrentDirectory }
    if (-not [IO.Directory]::Exists($workingDirectory)) { throw "$($Node.Name)：工作目录不存在：$workingDirectory" }
    $timeoutText = [string](Get-ConfigValue $Node.Config 'TimeoutSeconds' '')
    $hasTimeout = -not [string]::IsNullOrWhiteSpace($timeoutText)
    $timeoutSeconds = 0
    if ($hasTimeout -and (-not [int]::TryParse($timeoutText.Trim(), [ref]$timeoutSeconds) -or $timeoutSeconds -lt 1)) {
        throw "$($Node.Name)：超时秒数必须留空或填写大于 0 的整数。"
    }
    $outputVar = [string](Get-ConfigValue $Node.Config 'OutputVar' 'cmdResult')
    $failValue = Get-ConfigValue $Node.Config 'FailOnError' $true
    $failOnError = if ($failValue -is [bool]) { $failValue } else { [Convert]::ToBoolean([string]$failValue) }
    $cmdPath = Join-Path ([IO.Path]::GetTempPath()) ('PowerUI-WorkflowCmd-' + [guid]::NewGuid().ToString('N') + '.cmd')
    $cmdContent = "@echo off`r`n$command`r`n"
    [IO.File]::WriteAllText($cmdPath, $cmdContent, [Text.Encoding]::Default)
    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { 'cmd.exe' } else { $env:ComSpec }
        $info.Arguments = '/d /s /c ""' + $cmdPath + '""'
        $info.WorkingDirectory = $workingDirectory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($entry in $context.Env.GetEnumerator()) { $info.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value }
        try {
            $oemEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
            $info.StandardOutputEncoding = $oemEncoding
            $info.StandardErrorEncoding = $oemEncoding
        } catch { }
        Write-Output (Write-Event 'Log' "$($Node.Name)：开始执行 CMD" @{ WorkingDirectory = $workingDirectory })
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) { throw '无法启动 cmd.exe。' }
        Write-Output (Write-Event 'CommandStarted' "$($Node.Name)：CMD 进程已启动" @{ ProcessId = [int]$process.Id; NodeId = [string]$Node.Id; NodeName = [string]$Node.Name; Detached = $false; UnlimitedWait = (-not $hasTimeout); TimeoutSeconds = $timeoutSeconds })
        if (-not $hasTimeout) { Write-Output (Write-Event 'Log' "$($Node.Name)：未配置超时，将持续等待 CMD 结束，可在运行中任务里停止" @{ ProcessId = [int]$process.Id; UnlimitedWait = $true }) }
        $stdoutBuilder = New-Object Text.StringBuilder
        $stderrBuilder = New-Object Text.StringBuilder
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $deadline = if ($hasTimeout) { (Get-Date).AddSeconds($timeoutSeconds) } else { [datetime]::MaxValue }
        while ($true) {
            $handledLine = $false
            if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                $stdoutLine = $stdoutTask.Result
                if ($null -eq $stdoutLine) { $stdoutTask = $null }
                else {
                    Append-BoundedWorkerOutput $stdoutBuilder ([string]$stdoutLine) 4194304
                    Write-Output (Write-Event 'CommandOutput' (Limit-WorkerEventMessage ([string]$stdoutLine)) @{ Stream = 'stdout'; ProcessId = [int]$process.Id; NodeId = [string]$Node.Id; NodeName = [string]$Node.Name })
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
                $handledLine = $true
            }
            if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
                $stderrLine = $stderrTask.Result
                if ($null -eq $stderrLine) { $stderrTask = $null }
                else {
                    Append-BoundedWorkerOutput $stderrBuilder ([string]$stderrLine) 2097152
                    Write-Output (Write-Event 'CommandOutput' (Limit-WorkerEventMessage ([string]$stderrLine)) @{ Stream = 'stderr'; ProcessId = [int]$process.Id; NodeId = [string]$Node.Id; NodeName = [string]$Node.Name })
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
                $handledLine = $true
            }
            if ($process.HasExited -and $null -eq $stdoutTask -and $null -eq $stderrTask) { break }
            if ($hasTimeout -and -not $process.HasExited -and (Get-Date) -ge $deadline) {
                Stop-ChildProcessTree ([int]$process.Id)
                throw "执行超时（$timeoutSeconds 秒）。"
            }
            if (-not $handledLine) { Start-Sleep -Milliseconds 20 }
        }
        $process.WaitForExit()
        $stdout = $stdoutBuilder.ToString()
        $stderr = $stderrBuilder.ToString()
        $exitCode = [int]$process.ExitCode
        $result = [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout.TrimEnd(); StdErr = $stderr.TrimEnd(); ProcessId = [int]$process.Id; Started = $true; Detached = $false; UnlimitedWait = (-not $hasTimeout) }
        if (-not [string]::IsNullOrWhiteSpace($outputVar)) { $context.Vars[$outputVar] = $result }
        Write-Output (Write-Event 'Log' "$($Node.Name)：CMD 退出码 $exitCode" @{ ExitCode = $exitCode; OutputVar = $outputVar })
        if ($failOnError -and $exitCode -ne 0) { throw "CMD 返回非零退出码：$exitCode" }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $cmdPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PythonNode {
    param($Node)
    $mode = [string](Get-ConfigValue $Node.Config 'Mode' 'Inline')
    if ($mode -notin @('Inline','File')) { $mode = 'Inline' }
    $scriptValue = Resolve-Template ([string](Get-ConfigValue $Node.Config 'Script' ''))
    if ([string]::IsNullOrWhiteSpace($scriptValue)) { throw "$($Node.Name)：Python 脚本不能为空。" }
    $workingDirectory = Resolve-Template ([string](Get-ConfigValue $Node.Config 'WorkingDirectory' ''))
    $workingDirectory = [Environment]::ExpandEnvironmentVariables($workingDirectory.Trim())
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) { $workingDirectory = [Environment]::CurrentDirectory }
    if (-not [IO.Directory]::Exists($workingDirectory)) { throw "$($Node.Name)：工作目录不存在：$workingDirectory" }

    $configuredInterpreter = Resolve-Template ([string](Get-ConfigValue $Node.Config 'InterpreterPath' ''))
    $interpreterPath = [Environment]::ExpandEnvironmentVariables($configuredInterpreter.Trim())
    if ([string]::IsNullOrWhiteSpace($interpreterPath)) { $interpreterPath = 'python.exe' }
    if ([IO.Path]::IsPathRooted($interpreterPath)) {
        if (-not [IO.File]::Exists($interpreterPath)) { throw "$($Node.Name)：Python 解释器不存在：$interpreterPath" }
        $interpreterPath = [IO.Path]::GetFullPath($interpreterPath)
    } else {
        try {
            $pythonCommand = Get-Command $interpreterPath -CommandType Application -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $pythonCommand -and -not [string]::IsNullOrWhiteSpace([string]$pythonCommand.Source)) { $interpreterPath = [string]$pythonCommand.Source }
        } catch { }
    }

    $timeoutText = [string](Get-ConfigValue $Node.Config 'TimeoutSeconds' '')
    $hasTimeout = -not [string]::IsNullOrWhiteSpace($timeoutText)
    $timeoutSeconds = 0
    if ($hasTimeout -and (-not [int]::TryParse($timeoutText.Trim(), [ref]$timeoutSeconds) -or $timeoutSeconds -lt 1)) { throw "$($Node.Name)：超时秒数必须留空或填写大于 0 的整数。" }
    $argumentsText = Resolve-Template ([string](Get-ConfigValue $Node.Config 'Arguments' ''))
    $outputVar = [string](Get-ConfigValue $Node.Config 'OutputVar' 'pythonResult')
    $failValue = Get-ConfigValue $Node.Config 'FailOnError' $true
    $failOnError = if ($failValue -is [bool]) { $failValue } else { [Convert]::ToBoolean([string]$failValue) }

    $temporaryScriptPath = ''
    $scriptPath = ''
    if ($mode -eq 'File') {
        $scriptPath = [Environment]::ExpandEnvironmentVariables($scriptValue.Trim().Trim('"'))
        if (-not [IO.Path]::IsPathRooted($scriptPath)) { $scriptPath = Join-Path $workingDirectory $scriptPath }
        try { $scriptPath = [IO.Path]::GetFullPath($scriptPath) } catch { throw "$($Node.Name)：Python 脚本路径无效：$scriptPath" }
        if (-not [IO.File]::Exists($scriptPath)) { throw "$($Node.Name)：Python 脚本文件不存在：$scriptPath" }
    } else {
        $temporaryScriptPath = Join-Path ([IO.Path]::GetTempPath()) ('PowerUI-Python-' + [guid]::NewGuid().ToString('N') + '.py')
        [IO.File]::WriteAllText($temporaryScriptPath, $scriptValue, (New-Object Text.UTF8Encoding($false)))
        $scriptPath = $temporaryScriptPath
    }

    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $interpreterPath
        $info.Arguments = (ConvertTo-ProcessArgument $scriptPath) + $(if ([string]::IsNullOrWhiteSpace($argumentsText)) { '' } else { ' ' + $argumentsText.Trim() })
        $info.WorkingDirectory = $workingDirectory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($entry in $context.Env.GetEnumerator()) { $info.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value }
        $info.EnvironmentVariables['PYTHONUTF8'] = '1'
        $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        try { $info.StandardOutputEncoding = [Text.Encoding]::UTF8; $info.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
        Write-Output (Write-Event 'Log' "$($Node.Name)：开始执行 Python" @{ WorkingDirectory = $workingDirectory; InterpreterPath = $interpreterPath; Mode = $mode; ScriptPath = $scriptPath })
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) { throw '无法启动 Python。' }
        Write-Output (Write-Event 'CommandStarted' "$($Node.Name)：Python 进程已启动" @{ ProcessId = [int]$process.Id; ProcessKind = 'Python'; NodeId = [string]$Node.Id; NodeName = [string]$Node.Name; Detached = $false; UnlimitedWait = (-not $hasTimeout); TimeoutSeconds = $timeoutSeconds })
        if (-not $hasTimeout) { Write-Output (Write-Event 'Log' "$($Node.Name)：未配置超时，将持续等待 Python 结束，可在运行中任务里停止" @{ ProcessId = [int]$process.Id; UnlimitedWait = $true }) }
        $stdoutBuilder = New-Object Text.StringBuilder
        $stderrBuilder = New-Object Text.StringBuilder
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $deadline = if ($hasTimeout) { (Get-Date).AddSeconds($timeoutSeconds) } else { [datetime]::MaxValue }
        while ($true) {
            $handledLine = $false
            if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                $stdoutLine = $stdoutTask.Result
                if ($null -eq $stdoutLine) { $stdoutTask = $null } else { Append-BoundedWorkerOutput $stdoutBuilder ([string]$stdoutLine) 4194304; Write-Output (Write-Event 'CommandOutput' (Limit-WorkerEventMessage ([string]$stdoutLine)) @{ Stream = 'stdout'; ProcessKind = 'Python'; ProcessId = [int]$process.Id; NodeId = [string]$Node.Id; NodeName = [string]$Node.Name }); $stdoutTask = $process.StandardOutput.ReadLineAsync() }
                $handledLine = $true
            }
            if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
                $stderrLine = $stderrTask.Result
                if ($null -eq $stderrLine) { $stderrTask = $null } else { Append-BoundedWorkerOutput $stderrBuilder ([string]$stderrLine) 2097152; Write-Output (Write-Event 'CommandOutput' (Limit-WorkerEventMessage ([string]$stderrLine)) @{ Stream = 'stderr'; ProcessKind = 'Python'; ProcessId = [int]$process.Id; NodeId = [string]$Node.Id; NodeName = [string]$Node.Name }); $stderrTask = $process.StandardError.ReadLineAsync() }
                $handledLine = $true
            }
            if ($process.HasExited -and $null -eq $stdoutTask -and $null -eq $stderrTask) { break }
            if ($hasTimeout -and -not $process.HasExited -and (Get-Date) -ge $deadline) { Stop-ChildProcessTree ([int]$process.Id); throw "执行超时（$timeoutSeconds 秒）。" }
            if (-not $handledLine) { Start-Sleep -Milliseconds 20 }
        }
        $process.WaitForExit()
        $stdout = $stdoutBuilder.ToString()
        $stderr = $stderrBuilder.ToString()
        $exitCode = [int]$process.ExitCode
        $result = [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout.TrimEnd(); StdErr = $stderr.TrimEnd(); ProcessId = [int]$process.Id; InterpreterPath = $interpreterPath; WorkingDirectory = $workingDirectory; Mode = $mode; ScriptPath = $scriptPath; Started = $true; UnlimitedWait = (-not $hasTimeout) }
        if (-not [string]::IsNullOrWhiteSpace($outputVar)) { $context.Vars[$outputVar] = $result }
        Write-Output (Write-Event 'Log' "$($Node.Name)：Python 退出码 $exitCode" @{ ExitCode = $exitCode; OutputVar = $outputVar })
        if ($failOnError -and $exitCode -ne 0) { throw "Python 返回非零退出码：$exitCode" }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        if (-not [string]::IsNullOrWhiteSpace($temporaryScriptPath)) { Remove-Item -LiteralPath $temporaryScriptPath -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append([char]'\', (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append([char]'\', $backslashes); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append([char]'\', ($backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-CodexNode {
    param($Node)
    $defaultCodexPath = 'C:\Users\Admin\.codex\.sandbox-bin\codex.exe'
    $configuredPath = Resolve-Template ([string](Get-ConfigValue $Node.Config 'CodexPath' $defaultCodexPath))
    $codexPath = [Environment]::ExpandEnvironmentVariables($configuredPath)
    if ([string]::IsNullOrWhiteSpace($codexPath)) { $codexPath = $defaultCodexPath }
    if (-not [IO.File]::Exists($codexPath)) { throw "$($Node.Name)：Codex 路径不存在：$codexPath" }

    $configuredSessionId = Resolve-Template ([string](Get-ConfigValue $Node.Config 'SessionId' ''))
    $sessionId = [Environment]::ExpandEnvironmentVariables($configuredSessionId).Trim()
    $configuredDirectory = Resolve-Template ([string](Get-ConfigValue $Node.Config 'WorkingDirectory' '%TEMP%'))
    $workingDirectory = [Environment]::ExpandEnvironmentVariables($configuredDirectory)
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) { $workingDirectory = [IO.Path]::GetTempPath() }
    if ([string]::IsNullOrWhiteSpace($sessionId) -and -not [IO.Directory]::Exists($workingDirectory)) { throw "$($Node.Name)：默认工作目录不存在：$workingDirectory" }
    $processWorkingDirectory = if ([IO.Directory]::Exists($workingDirectory)) { $workingDirectory } else { [IO.Path]::GetTempPath() }

    $request = Resolve-Template ([string](Get-ConfigValue $Node.Config 'Request' ''))
    if ([string]::IsNullOrWhiteSpace($request)) { throw "$($Node.Name)：需求内容不能为空。" }
    $liveData = Resolve-Template ([string](Get-ConfigValue $Node.Config 'LiveData' ''))
    $prompt = $request.Trim()
    if (-not [string]::IsNullOrWhiteSpace($liveData)) { $prompt += "`r`n`r`n附带的实时数据：`r`n" + $liveData.Trim() }

    $timeoutSeconds = [int](Get-ConfigValue $Node.Config 'TimeoutSeconds' 600)
    if ($timeoutSeconds -lt 1) { $timeoutSeconds = 600 }
    $model = (Resolve-Template ([string](Get-ConfigValue $Node.Config 'Model' ''))).Trim()
    $outputVar = [string](Get-ConfigValue $Node.Config 'OutputVar' 'codexResult')
    $failValue = Get-ConfigValue $Node.Config 'FailOnError' $true
    $failOnError = if ($failValue -is [bool]) { $failValue } else { [Convert]::ToBoolean([string]$failValue) }

    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $codexPath
        $invocationMode = if ([string]::IsNullOrWhiteSpace($sessionId)) { 'New' } else { 'Resume' }
        $modelArgument = if ([string]::IsNullOrWhiteSpace($model)) { '' } else { ' --model ' + (ConvertTo-ProcessArgument $model) }
        if ($invocationMode -eq 'Resume') {
            $info.Arguments = 'exec --yolo --skip-git-repo-check' + $modelArgument + ' resume ' + (ConvertTo-ProcessArgument $sessionId) + ' ' + (ConvertTo-ProcessArgument $prompt)
        } else {
            $info.Arguments = '-C ' + (ConvertTo-ProcessArgument $workingDirectory) + ' exec --yolo --skip-git-repo-check' + $modelArgument + ' ' + (ConvertTo-ProcessArgument $prompt)
        }
        $info.WorkingDirectory = $processWorkingDirectory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($entry in $context.Env.GetEnumerator()) { $info.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value }
        try {
            $info.StandardOutputEncoding = [Text.Encoding]::UTF8
            $info.StandardErrorEncoding = [Text.Encoding]::UTF8
        } catch { }

        $invocationSummary = if ($invocationMode -eq 'Resume') { 'exec resume <SESSION_ID> <PROMPT>' } else { '-C <DIR> exec <PROMPT>' }
        Write-Output (Write-Event 'Log' "$($Node.Name)：开始调用 Codex（$invocationMode：$invocationSummary）" @{ CodexPath = $codexPath; WorkingDirectory = $processWorkingDirectory; SessionId = $sessionId; Model = $model; InvocationMode = $invocationMode; OutputVar = $outputVar })
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) { throw '无法启动 Codex。' }
        Write-Output (Write-Event 'CodexStarted' "$($Node.Name)：Codex 进程已启动" @{ ProcessId = [int]$process.Id; SessionId = $sessionId; Model = $model; NodeId = [string]$Node.Id; NodeName = [string]$Node.Name })
        $stdoutBuilder = New-Object Text.StringBuilder
        $stderrBuilder = New-Object Text.StringBuilder
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $deadline = (Get-Date).AddSeconds($timeoutSeconds)
        while ($true) {
            $handledLine = $false
            if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                $stdoutLine = $stdoutTask.Result
                if ($null -eq $stdoutLine) { $stdoutTask = $null } else { Append-BoundedWorkerOutput $stdoutBuilder ([string]$stdoutLine) 4194304; $stdoutTask = $process.StandardOutput.ReadLineAsync() }
                $handledLine = $true
            }
            if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
                $stderrLine = $stderrTask.Result
                if ($null -eq $stderrLine) { $stderrTask = $null } else { Append-BoundedWorkerOutput $stderrBuilder ([string]$stderrLine) 2097152; $stderrTask = $process.StandardError.ReadLineAsync() }
                $handledLine = $true
            }
            if ($process.HasExited -and $null -eq $stdoutTask -and $null -eq $stderrTask) { break }
            if (-not $process.HasExited -and (Get-Date) -ge $deadline) {
                Stop-ChildProcessTree ([int]$process.Id)
                throw "Codex 执行超时（$timeoutSeconds 秒）。"
            }
            if (-not $handledLine) { Start-Sleep -Milliseconds 20 }
        }
        $process.WaitForExit()
        $stdout = $stdoutBuilder.ToString()
        $stderr = $stderrBuilder.ToString()
        $exitCode = [int]$process.ExitCode
        $result = [pscustomobject]@{
            ExitCode = $exitCode
            StdOut = $stdout.TrimEnd()
            StdErr = $stderr.TrimEnd()
            CodexPath = $codexPath
            WorkingDirectory = $processWorkingDirectory
            SessionId = $sessionId
            Model = $model
            InvocationMode = $invocationMode
        }
        if (-not [string]::IsNullOrWhiteSpace($outputVar)) { $context.Vars[$outputVar] = $result }
        Write-Output (Write-Event 'Log' "$($Node.Name)：Codex 退出码 $exitCode" @{ ExitCode = $exitCode; OutputVar = $outputVar })
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $logText = $stdout.Trim(); if ($logText.Length -gt 3000) { $logText = $logText.Substring(0, 3000) + '...' }
            Write-Output (Write-Event 'Log' "$($Node.Name) 输出：$logText" @{})
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $logText = $stderr.Trim(); if ($logText.Length -gt 3000) { $logText = $logText.Substring(0, 3000) + '...' }
            Write-Output (Write-Event 'Log' "$($Node.Name) 错误输出：$logText" @{})
        }
        if ($failOnError -and $exitCode -ne 0) { throw "Codex 返回非零退出码：$exitCode" }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Invoke-HttpNode {
    param($Node)
    $config = $Node.Config
    $url = Resolve-Template ([string]$config.Url)
    if ([string]::IsNullOrWhiteSpace($url)) { throw ('网络请求节点：' + $Node.Name + '缺少 URL。') }
    $headers = Convert-Headers ([string]$config.Headers)
    $contentType = 'application/json'
    $contentTypeKey = @($headers.Keys | Where-Object { $_ -ieq 'Content-Type' } | Select-Object -First 1)
    if ($contentTypeKey.Count -gt 0) { $contentType = [string]$headers[$contentTypeKey[0]]; $headers.Remove($contentTypeKey[0]) }
    $method = ([string]$config.Method).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($method)) { $method = 'GET' }
    Write-Output (Write-Event 'Log' "$($Node.Name)：$method $url" @{})
    $params = @{ Uri = $url; Method = $method; Headers = $headers; WebSession = $context.Session; UseBasicParsing = $true; TimeoutSec = 45 }
    if ($method -ne 'GET' -and $method -ne 'HEAD') {
        $body = Resolve-Template ([string]$config.Body)
        if (-not [string]::IsNullOrEmpty($body)) { $params.Body = [Text.Encoding]::UTF8.GetBytes($body); $params.ContentType = $contentType }
    }
    try {
        $response = Invoke-WebRequest @params
        $content = [string]$response.Content
        try { $parsed = $content | ConvertFrom-Json } catch { $parsed = $content }
        $responseVar = [string]$config.ResponseVar
        if (-not [string]::IsNullOrWhiteSpace($responseVar)) { $context.Vars[$responseVar] = $parsed }
        $status = [int]$response.StatusCode
        Write-Output (Write-Event 'Log' "$($Node.Name)：HTTP $status" @{ StatusCode = $status; ResponseVar = $responseVar })
        if ($status -ge 400) { throw "网络请求返回 HTTP $status。" }
        $expectedCode = [string]$config.ExpectedCode
        if (-not [string]::IsNullOrWhiteSpace($expectedCode) -and $null -ne $parsed -and $null -ne $parsed.PSObject.Properties['code']) {
            if ([int]$parsed.code -ne [int]$expectedCode) { throw "$($Node.Name)：接口业务码 $($parsed.code)，期望 $expectedCode。" }
        }
    } catch {
        throw "$($Node.Name)：$($_.Exception.Message)"
    }
}

function Invoke-WorkflowNode {
    param($Node)
    switch ([string]$Node.Type) {
        'Start' { Write-Output (Write-Event 'Log' '工作流开始' @{}) }
        'End' { Write-Output (Write-Event 'Log' '工作流结束' @{}) }
        'HttpRequest' { Invoke-HttpNode $Node }
        'Cmd' { Invoke-CmdNode $Node }
        'Python' { Invoke-PythonNode $Node }
        'Codex' { Invoke-CodexNode $Node }
        'EnvRead' {
            $items = @(Get-EnvironmentItems $Node.Config -Read)
            if ($items.Count -eq 0) { throw "$($Node.Name)：至少需要配置一行环境变量映射。" }
            foreach ($item in $items) {
                $name = [string](Get-ConfigValue $item 'Name' '')
                $variable = [string](Get-ConfigValue $item 'Variable' '')
                if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($variable)) { throw "$($Node.Name)：环境变量名和任务变量名不能为空。" }
                $value = Get-TaskEnvironmentValue $name
                if ($null -eq $value) { throw "环境变量不存在：$name" }
                $context.Vars[$variable] = [string]$value
            }
            Write-Output (Write-Event 'Log' "$($Node.Name)：已导入 $($items.Count) 个环境变量" @{})
        }
        'EnvWrite' {
            $items = @(Get-EnvironmentItems $Node.Config)
            if ($items.Count -eq 0) { throw "$($Node.Name)：至少需要配置一行变量和值。" }
            foreach ($item in $items) {
                $name = [string](Get-ConfigValue $item 'Name' '')
                if ([string]::IsNullOrWhiteSpace($name)) { throw "$($Node.Name)：变量名不能为空。" }
                $valueType = [string](Get-ConfigValue $item 'ValueType' 'String')
                if ([string]::IsNullOrWhiteSpace($valueType)) { $valueType = 'String' }
                $resolvedValue = Resolve-Template (ConvertTo-TaskString (Get-ConfigValue $item 'Value' ''))
                $value = ConvertTo-WorkflowValue $resolvedValue $valueType $Node.Name
                $context.Env[$name] = ConvertTo-TaskString $value
                $context.Vars[$name] = $value
            }
            Write-Output (Write-Event 'Log' "$($Node.Name)：已定义 $($items.Count) 个任务变量" @{})
        }
        'Variable' {
            $name = [string](Get-ConfigValue $Node.Config 'Name' '')
            if ([string]::IsNullOrWhiteSpace($name)) { throw "$($Node.Name)：变量名不能为空。" }
            $valueType = [string](Get-ConfigValue $Node.Config 'ValueType' 'String')
            $value = ConvertTo-WorkflowValue (Get-ConfigValue $Node.Config 'Value' '') $valueType $Node.Name
            Set-WorkflowVariable $name $value
            Write-Output (Write-Event 'Log' "$($Node.Name)：已写入变量 $name（$valueType）" @{ Variable = $name; ValueType = $valueType })
        }
        'If' {
            $result = [bool](Test-WorkflowCondition $Node)
            $context.Control['IfResult'] = $result
            $outputVar = [string](Get-ConfigValue $Node.Config 'OutputVar' '')
            if (-not [string]::IsNullOrWhiteSpace($outputVar)) { Set-WorkflowVariable $outputVar $result }
            Write-Output (Write-Event 'Log' "$($Node.Name)：判断结果 $result" @{ Result = $result; OutputVar = $outputVar })
        }
        'Delay' {
            $seconds = [double](Get-ConfigValue $Node.Config 'Seconds' 1)
            $seconds = [Math]::Min(86400, [Math]::Max(0, $seconds))
            if ($seconds -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Round($seconds * 1000)) }
            Write-Output (Write-Event 'Log' "$($Node.Name)：已延时 $seconds 秒" @{ Seconds = $seconds })
        }
        'LoopEnd' { Write-Output (Write-Event 'Log' "$($Node.Name)：本次循环体结束" @{}) }
        'Balloon' {
            $title = Resolve-Template ([string]$Node.Config.Title)
            $message = Resolve-Template ([string]$Node.Config.Message)
            $clickAction = [string](Get-ConfigValue $Node.Config 'ClickAction' 'None')
            $clickTarget = Resolve-Template ([string](Get-ConfigValue $Node.Config 'ClickTarget' ''))
            Write-Output (Write-Event 'Balloon' $message @{ Title = $title; ClickAction = $clickAction; ClickTarget = $clickTarget })
            Write-Output (Write-Event 'Log' "$($Node.Name)：已发送气泡提醒" @{})
        }
        default { throw "不支持的节点类型：$($Node.Type)" }
    }
}

$nodes = @{}
foreach ($node in @($workflow.Nodes)) { $nodes[[string]$node.Id] = $node }
$outgoing = @{}
foreach ($edge in @($workflow.Edges)) {
    $source = [string]$edge.From
    if (-not $outgoing.ContainsKey($source)) { $outgoing[$source] = @() }
    $outgoing[$source] += $edge
}

function Get-ControlEdge {
    param([string]$Id, [string]$Branch, [int]$FallbackIndex)
    if (-not $outgoing.ContainsKey($Id)) { return $null }
    $edges = @($outgoing[$Id])
    $matched = @($edges | Where-Object { [string](Get-ConfigValue $_ 'Branch' '') -eq $Branch } | Select-Object -First 1)
    if ($matched.Count -gt 0) { return $matched[0] }
    if ($FallbackIndex -ge 0 -and $FallbackIndex -lt $edges.Count) { return $edges[$FallbackIndex] }
    return $null
}

function Walk-Node {
    param([string]$Id, [hashtable]$Visited = $null, [switch]$StopAtLoopEnd)
    if ($null -eq $Visited) { $Visited = @{} }
    if ($Visited.ContainsKey($Id)) { return }
    if (-not $nodes.ContainsKey($Id)) { throw "连线指向不存在的节点：$Id" }
    $context.ExecutionCount++
    if ($context.ExecutionCount -gt 10000) { throw '节点执行次数超过 10000，工作流可能存在未收束的循环。' }
    $node = $nodes[$Id]
    $Visited[$Id] = $true
    Write-Output (Write-Event 'NodeStart' ([string]$node.Name) @{ NodeId = [string]$node.Id; NodeName = [string]$node.Name; NodeType = [string]$node.Type })

    if ([string]$node.Type -eq 'ForEach') {
        $items = @(Get-WorkflowLoopItems $node)
        $itemVariable = [string](Get-ConfigValue $node.Config 'ItemVariable' 'item')
        $indexVariable = [string](Get-ConfigValue $node.Config 'IndexVariable' 'index')
        $resultVariable = [string](Get-ConfigValue $node.Config 'ResultVariable' 'loopResult')
        if ([string]::IsNullOrWhiteSpace($itemVariable)) { throw "$($node.Name)：当前项变量名不能为空。" }
        $bodyEdge = Get-ControlEdge $Id 'Body' 0
        $doneEdge = Get-ControlEdge $Id 'Done' 1
        Write-Output (Write-Event 'Log' "$($node.Name)：开始遍历 $($items.Count) 项" @{ Count = $items.Count })
        for ($index = 0; $index -lt $items.Count; $index++) {
            Set-WorkflowVariable $itemVariable $items[$index]
            if (-not [string]::IsNullOrWhiteSpace($indexVariable)) { Set-WorkflowVariable $indexVariable ($index + 1) }
            Write-Output (Write-Event 'Log' "$($node.Name)：执行第 $($index + 1)/$($items.Count) 项" @{ Index = ($index + 1); Count = $items.Count })
            if ($null -ne $bodyEdge) { Walk-Node ([string]$bodyEdge.To) @{} -StopAtLoopEnd }
        }
        if (-not [string]::IsNullOrWhiteSpace($resultVariable)) {
            Set-WorkflowVariable $resultVariable ([pscustomobject]@{ Count = $items.Count; LastIndex = $items.Count })
        }
        Write-Output (Write-Event 'Log' "$($node.Name)：遍历完成" @{ Count = $items.Count; ResultVariable = $resultVariable })
        Write-Output (Write-Event 'NodeComplete' ([string]$node.Name) @{ NodeId = [string]$node.Id; NodeName = [string]$node.Name; NodeType = [string]$node.Type })
        if ($null -ne $doneEdge) { Walk-Node ([string]$doneEdge.To) $Visited -StopAtLoopEnd:$StopAtLoopEnd }
        return
    }

    Invoke-WorkflowNode $node
    Write-Output (Write-Event 'NodeComplete' ([string]$node.Name) @{ NodeId = [string]$node.Id; NodeName = [string]$node.Name; NodeType = [string]$node.Type })
    if ([string]$node.Type -eq 'LoopEnd' -and $StopAtLoopEnd) { return }
    if ([string]$node.Type -eq 'If') {
        $branch = if ([bool]$context.Control['IfResult']) { 'True' } else { 'False' }
        $fallback = if ($branch -eq 'True') { 0 } else { 1 }
        $edge = Get-ControlEdge $Id $branch $fallback
        if ($null -ne $edge) { Walk-Node ([string]$edge.To) $Visited -StopAtLoopEnd:$StopAtLoopEnd }
        return
    }
    if ($outgoing.ContainsKey($Id)) {
        foreach ($edge in @($outgoing[$Id])) { Walk-Node ([string]$edge.To) $Visited -StopAtLoopEnd:$StopAtLoopEnd }
    }
}
$start = @($workflow.Nodes | Where-Object { $_.Type -eq 'Start' } | Select-Object -First 1)
if ($start.Count -eq 0) { throw '工作流缺少开始节点。' }
try {
    Write-Output (Write-Event 'Log' "开始执行：$($workflow.Name)" @{})
    Walk-Node ([string]$start[0].Id) @{}
    Write-Output (Write-Event 'Done' '执行完成' @{})
} catch {
    Write-Output (Write-Event 'Error' $_.Exception.Message @{})
    exit 1
}
'@

[void][WorkflowNativeMethods]::EnablePerMonitorDpi()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

function New-UiFont {
    param([float]$Size = 9, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    return New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
}

function Set-WorkflowFormScaling {
    param([Windows.Forms.Form]$Form)
    if($null-eq$Form-or$Form.IsDisposed){return}
    $Form.AutoScaleMode=[Windows.Forms.AutoScaleMode]::Dpi
    $Form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96)
}

function ConvertTo-UiColor {
    param([string]$Value, [Drawing.Color]$Fallback)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }
    try {
        $normalized=$Value.Trim()
        if($normalized-match'^[0-9A-Fa-f]{6}$'){$normalized='#'+$normalized}
        if($normalized-notmatch'^#[0-9A-Fa-f]{6}$'){return $Fallback}
        return [Drawing.ColorTranslator]::FromHtml($normalized)
    } catch { return $Fallback }
}

function ConvertTo-UiColorHex {
    param([Drawing.Color]$Color)
    return ('#{0:X2}{1:X2}{2:X2}' -f $Color.R,$Color.G,$Color.B)
}

function Set-UiColorPickerButton {
    param([Windows.Forms.Button]$Button,[string]$Value,[Drawing.Color]$Fallback)
    if($null-eq$Button){return}
    $color=ConvertTo-UiColor $Value $Fallback
    $hex=ConvertTo-UiColorHex $color
    $Button.Tag=$hex;$Button.Text=$hex;$Button.BackColor=$color;$Button.UseVisualStyleBackColor=$false
    $luminance=(0.299*$color.R)+(0.587*$color.G)+(0.114*$color.B)
    $Button.ForeColor=if($luminance-lt145){[Drawing.Color]::White}else{[Drawing.Color]::FromArgb(15,23,42)}
    $Button.FlatAppearance.BorderColor=[Windows.Forms.ControlPaint]::Dark($color)
}

function Show-UiColorPicker {
    param([Windows.Forms.Button]$Button,[Windows.Forms.Form]$Owner,[Drawing.Color]$Fallback)
    if($null-eq$Button){return}
    $dialog=New-Object Windows.Forms.ColorDialog;$dialog.FullOpen=$true;$dialog.AnyColor=$true;$dialog.Color=ConvertTo-UiColor ([string]$Button.Tag) $Fallback
    try{if($dialog.ShowDialog($Owner)-eq[Windows.Forms.DialogResult]::OK){Set-UiColorPickerButton $Button (ConvertTo-UiColorHex $dialog.Color) $Fallback}}finally{$dialog.Dispose()}
}

function Get-CodexConversationPalette {
    $settings=$script:GlobalSettings
    return [pscustomobject]@{
        Surface=ConvertTo-UiColor ([string](Get-UiConfigValue $settings 'ConversationSurfaceColor' '#F8FAFC')) ([Drawing.Color]::FromArgb(248,250,252))
        UserBubble=ConvertTo-UiColor ([string](Get-UiConfigValue $settings 'ConversationUserBubbleColor' '#DBEAFE')) ([Drawing.Color]::FromArgb(219,234,254))
        AssistantBubble=ConvertTo-UiColor ([string](Get-UiConfigValue $settings 'ConversationAssistantBubbleColor' '#FFFFFF')) ([Drawing.Color]::White)
        InputBackground=ConvertTo-UiColor ([string](Get-UiConfigValue $settings 'ConversationInputBackgroundColor' '#FFFFFF')) ([Drawing.Color]::White)
        InputText=ConvertTo-UiColor ([string](Get-UiConfigValue $settings 'ConversationInputTextColor' '#0F172A')) ([Drawing.Color]::FromArgb(15,23,42))
    }
}

function Apply-CodexConversationPalette {
    $palette=Get-CodexConversationPalette
    if($null-ne$script:CodexConversationPanel){$script:CodexConversationPanel.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationSplit){$script:CodexConversationSplit.BackColor=[Windows.Forms.ControlPaint]::Dark($palette.Surface);$script:CodexConversationSplit.Panel1.BackColor=$palette.Surface;$script:CodexConversationSplit.Panel2.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationLayout){$script:CodexConversationLayout.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationHeader){$script:CodexConversationHeader.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationComposer){$script:CodexConversationComposer.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationComposerLayout){$script:CodexConversationComposerLayout.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationActions){$script:CodexConversationActions.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationOutputHost){$script:CodexConversationOutputHost.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationOutput){$script:CodexConversationOutput.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationBottomSpacer-and-not$script:CodexConversationBottomSpacer.IsDisposed){$script:CodexConversationBottomSpacer.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationInputFrame){$script:CodexConversationInputFrame.BackColor=[Windows.Forms.ControlPaint]::Dark($palette.Surface)}
    if($null-ne$script:CodexConversationInputSurface){$script:CodexConversationInputSurface.BackColor=$palette.InputBackground}
    if($null-ne$script:CodexConversationAttachmentPreview){$script:CodexConversationAttachmentPreview.BackColor=$palette.InputBackground}
    if($null-ne$script:CodexConversationInput){$script:CodexConversationInput.BackColor=$palette.InputBackground;$script:CodexConversationInput.ForeColor=$palette.InputText}
    if($null-ne$script:CodexConversationSearchFrame){$script:CodexConversationSearchFrame.BackColor=[Windows.Forms.ControlPaint]::Dark($palette.Surface)}
    if($null-ne$script:CodexConversationSearchBox){$script:CodexConversationSearchBox.BackColor=$palette.InputBackground;$script:CodexConversationSearchBox.ForeColor=$palette.InputText}
    if($null-ne$script:CodexConversationFileTreePanel){$script:CodexConversationFileTreePanel.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationFileTreeHeader){$script:CodexConversationFileTreeHeader.BackColor=$palette.Surface}
    if($null-ne$script:CodexConversationFileTreeHost){$script:CodexConversationFileTreeHost.BackColor=[Windows.Forms.ControlPaint]::Dark($palette.Surface)}
    if($null-ne$script:CodexConversationFileTree){$script:CodexConversationFileTree.BackColor=$palette.InputBackground;$script:CodexConversationFileTree.ForeColor=$palette.InputText}
    foreach($record in @($script:CodexConversationBubbleRecords)){
        if($null-eq$record-or$record.Row.IsDisposed){continue}
        $color=if([string]$record.Role-eq'user'){$palette.UserBubble}else{$palette.AssistantBubble}
        $record.Row.BackColor=$palette.Surface;$record.Bubble.FillColor=$color;$record.Bubble.BorderColor=[Windows.Forms.ControlPaint]::Dark($color);$record.TextBox.BackColor=$color
        $selectionStart=$record.TextBox.SelectionStart;$selectionLength=$record.TextBox.SelectionLength
        try{$record.TextBox.SelectAll();$record.TextBox.SelectionBackColor=$color}finally{$record.TextBox.SelectionStart=[Math]::Min($selectionStart,$record.TextBox.TextLength);$record.TextBox.SelectionLength=[Math]::Min($selectionLength,[Math]::Max(0,$record.TextBox.TextLength-$record.TextBox.SelectionStart))}
    }
}

function Get-ApplicationIcon {
    if ($null -ne $script:ApplicationIcon) { return $script:ApplicationIcon }
    $loadedIcon = $null
    $disposeLoadedIcon = $false
    try {
        $loadedIcon = New-WorkflowIconForSize 32
        $disposeLoadedIcon = $true
        if ($null -eq $loadedIcon) { $loadedIcon = [Drawing.SystemIcons]::Application }
        $script:ApplicationIcon = [Drawing.Icon]$loadedIcon.Clone()
    } catch {
        $script:ApplicationIcon = [Drawing.Icon][Drawing.SystemIcons]::Application.Clone()
    } finally {
        if ($disposeLoadedIcon -and $null -ne $loadedIcon) { $loadedIcon.Dispose() }
    }
    return $script:ApplicationIcon
}

function Get-SmallApplicationIcon {
    if ($null -eq $script:SmallApplicationIcon) {
        try { $script:SmallApplicationIcon = New-WorkflowIconForSize 16 }
        catch { $script:SmallApplicationIcon = New-Object Drawing.Icon((Get-ApplicationIcon), (New-Object Drawing.Size(16, 16))) }
    }
    return $script:SmallApplicationIcon
}

function New-WorkflowIconForSize {
    param([int]$Size)
    $targetSize = [Math]::Max(16, [Math]::Min(256, $Size))
    try {
        $executablePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $executableName = [IO.Path]::GetFileNameWithoutExtension($executablePath)
        if (-not [string]::IsNullOrWhiteSpace($executablePath) -and $executableName -notin @('powershell','pwsh')) {
            return (New-Object Drawing.Icon -ArgumentList @($executablePath, $targetSize, $targetSize))
        }
    } catch { }
    return [WorkflowIconFactory]::Create($targetSize)
}

function Get-CurrentWorkflowDpi {
    if ($null -ne $script:MainForm -and -not $script:MainForm.IsDisposed) {
        try { return [WorkflowNativeMethods]::GetWindowDpi($script:MainForm) } catch { }
        try {
            $graphics = $script:MainForm.CreateGraphics()
            try { return [int][Math]::Round($graphics.DpiX) } finally { $graphics.Dispose() }
        } catch { }
    }
    return 96
}

function ConvertTo-WorkflowDpiPixels {
    param([int]$Value,[int]$Minimum=1)
    $dpi=[Math]::Max(96,(Get-CurrentWorkflowDpi))
    return [Math]::Max($Minimum,[int][Math]::Round(($Value*$dpi)/96.0))
}

function Get-TrayIconPixelSize {
    $dpi = [Math]::Max(96, (Get-CurrentWorkflowDpi))
    return [Math]::Max(16, [Math]::Min(64, [int][Math]::Round((16.0 * $dpi) / 96.0)))
}

function Get-TrayIcon {
    $targetSize = Get-TrayIconPixelSize
    if ($null -eq $script:TrayIcon -or $script:TrayIconSize -ne $targetSize) {
        $previousIcon = $script:TrayIcon
        try { $newIcon = New-WorkflowIconForSize $targetSize }
        catch { $newIcon = New-Object Drawing.Icon((Get-ApplicationIcon), (New-Object Drawing.Size($targetSize, $targetSize))) }
        $script:TrayIcon = $newIcon
        $script:TrayIconSize = $targetSize
        if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Icon = $newIcon }
        if ($null -ne $previousIcon) { try { $previousIcon.Dispose() } catch { } }
    }
    return $script:TrayIcon
}

function Set-WorkflowWindowIcon {
    param([System.Windows.Forms.Form]$Form)
    if ($null -eq $Form -or $Form.IsDisposed) { return }
    $largeIcon = Get-ApplicationIcon
    $smallIcon = Get-SmallApplicationIcon
    $Form.ShowIcon = $true
    $Form.Icon = $largeIcon
    if ($Form.IsHandleCreated) { [WorkflowNativeMethods]::ApplyWindowIcons($Form, $smallIcon, $largeIcon) }
}

function Get-UiIndexedItemSafe {
    param($Collection, [int]$Index)
    if ($null -eq $Collection -or $Index -lt 0) { return $null }
    try {
        $count = [int]$Collection.Count
        if ($Index -ge $count) { return $null }
        $item = $Collection[$Index]
        return ,$item
    } catch {
        return $null
    }
}

function Get-UiSelectedItemSafe {
    param($Collection)
    if ($null -eq $Collection) { return $null }
    try {
        if ([int]$Collection.Count -le 0) { return $null }
        return Get-UiIndexedItemSafe $Collection 0
    } catch {
        return $null
    }
}

function Add-UiLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 100, [int]$Height = 24, [switch]$Muted)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.Font = New-UiFont 9
    if ($Muted) { $label.ForeColor = [Drawing.Color]::FromArgb(92, 105, 120) }
    $Parent.Controls.Add($label)
    return $label
}

function Add-UiButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 88, [int]$Height = 32, [ValidateSet('Default','Primary','Node','Danger')] [string]$Variant = 'Default')
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.Font = New-UiFont 9
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.FlatAppearance.BorderSize = 1
    $button.Padding = New-Object Windows.Forms.Padding(0)
    $button.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $button.AutoSize = $false
    switch ($Variant) {
        'Primary' {
            $button.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
            $button.ForeColor = [Drawing.Color]::White
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(29, 78, 216)
            $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(29, 78, 216)
            $button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(30, 64, 175)
        }
        'Node' {
            $button.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)
            $button.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(203, 213, 225)
            $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(238, 242, 255)
            $button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(224, 231, 255)
        }
        'Danger' {
            $button.BackColor = [Drawing.Color]::White
            $button.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(254, 202, 202)
            $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(254, 242, 242)
            $button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(254, 226, 226)
        }
        default {
            $button.BackColor = [Drawing.Color]::White
            $button.ForeColor = [Drawing.Color]::FromArgb(51, 65, 85)
            $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(203, 213, 225)
            $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(241, 245, 249)
            $button.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(226, 232, 240)
        }
    }
    $Parent.Controls.Add($button)
    return $button
}

function Apply-UiTheme {
    param([System.Windows.Forms.Control]$Root)
    if ($null -eq $Root -or $Root.IsDisposed) { return }
    if($Root -is [Windows.Forms.Form]){Set-WorkflowFormScaling $Root}

    if ($Root -is [Windows.Forms.TextBox]) {
        if ([string]$Root.Tag -eq 'CodexConversationInput') {
            $palette=Get-CodexConversationPalette
            $Root.BorderStyle = [Windows.Forms.BorderStyle]::None
            $Root.BackColor = $palette.InputBackground
            $Root.ForeColor = $palette.InputText
            $Root.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10.5)
        } elseif ([string]$Root.Tag -eq 'WorkflowNameInput') {
            $Root.BorderStyle = [Windows.Forms.BorderStyle]::None
            $Root.BackColor = [Drawing.Color]::White
            $Root.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
            $Root.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10.5)
        } elseif ([string]$Root.Tag -eq 'CodexConversationSearch') {
            $palette=Get-CodexConversationPalette
            $Root.BorderStyle = [Windows.Forms.BorderStyle]::None
            $Root.BackColor = $palette.InputBackground
            $Root.ForeColor = $palette.InputText
            $Root.Font = New-UiFont 9
            try { [WorkflowNativeMethods]::ApplyTextMargins($Root, 6) } catch { }
        } else {
            $Root.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
            $Root.BackColor = if ($Root.ReadOnly) { [Drawing.Color]::FromArgb(241, 245, 249) } else { [Drawing.Color]::White }
            $Root.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
            if ($Root.Font.FontFamily.Name -ne 'Consolas') { $Root.Font = New-UiFont 9.5 }
            try { [WorkflowNativeMethods]::ApplyTextMargins($Root, 7) } catch { }
        }
    } elseif ($Root -is [Windows.Forms.RichTextBox]) {
        $Root.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)
        $Root.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
        $Root.BorderStyle = [Windows.Forms.BorderStyle]::None
    } elseif ($Root -is [Windows.Forms.ComboBox]) {
        $Root.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $Root.BackColor = [Drawing.Color]::White
        $Root.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
        $Root.Font = if([string]$Root.Tag-eq'ProjectSelector'){New-Object Drawing.Font('Microsoft YaHei UI',10)}else{New-UiFont 9.5}
        $Root.DropDownHeight = if([string]$Root.Tag-eq'CodexSessionSelector'){280}else{240}
        $Root.IntegralHeight = [string]$Root.Tag -ne 'CodexSessionSelector'
        if([string]$Root.Tag-eq'ProjectSelector'){$Root.DropDownWidth=[Math]::Max(300,$Root.Width)}
        elseif([string]$Root.Tag-eq'CodexSessionSelector'){$Root.DrawMode=[Windows.Forms.DrawMode]::OwnerDrawFixed;$Root.ItemHeight=30;$Root.DropDownWidth=[Math]::Max(280,$Root.Width)}
    } elseif ($Root -is [Windows.Forms.NumericUpDown]) {
        $Root.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
        $Root.BackColor = [Drawing.Color]::White
        $Root.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
        $Root.Font = New-UiFont 9.5
    } elseif ($Root -is [Windows.Forms.CheckBox]) {
        $Root.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $Root.ForeColor = [Drawing.Color]::FromArgb(51, 65, 85)
        $Root.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(148, 163, 184)
        $Root.Font = New-UiFont 9
    } elseif ($Root -is [Windows.Forms.ListBox]) {
        $Root.BorderStyle = [Windows.Forms.BorderStyle]::None
        $Root.BackColor = if([string]$Root.Tag-eq'WorkflowTaskList'){[Drawing.Color]::White}else{[Drawing.Color]::FromArgb(248, 250, 252)}
        $Root.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
        $Root.Font = if([string]$Root.Tag-eq'WorkflowTaskList'){New-Object Drawing.Font('Microsoft YaHei UI',10)}else{New-UiFont 9.5}
        $Root.IntegralHeight = $false
    } elseif ($Root -is [Windows.Forms.DataGridView]) {
        $Root.BorderStyle = [Windows.Forms.BorderStyle]::None
        $Root.BackgroundColor = [Drawing.Color]::FromArgb(248, 250, 252)
        $Root.GridColor = [Drawing.Color]::FromArgb(226, 232, 240)
        $Root.EnableHeadersVisualStyles = $false
        $Root.ColumnHeadersBorderStyle = [Windows.Forms.DataGridViewHeaderBorderStyle]::Single
        $Root.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(241, 245, 249)
        $Root.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(51, 65, 85)
        $Root.ColumnHeadersDefaultCellStyle.Font = New-UiFont 9 ([Drawing.FontStyle]::Bold)
        $Root.DefaultCellStyle.BackColor = [Drawing.Color]::White
        $Root.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
        $Root.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(219, 234, 254)
        $Root.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::FromArgb(30, 64, 175)
        $Root.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)
    } elseif ($Root -is [Windows.Forms.StatusStrip]) {
        $Root.BackColor = [Drawing.Color]::White
        $Root.ForeColor = [Drawing.Color]::FromArgb(71, 85, 105)
        $Root.SizingGrip = $false
    }

    foreach ($child in @($Root.Controls)) { Apply-UiTheme $child }
}

function Show-Message {
    param([string]$Text, [string]$Title = $script:AppName, [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information)
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon) | Out-Null
}

function Get-CodexConversationAttachmentDirectory {
    return (Join-Path $script:DataDirectory 'attachments')
}

function Get-CodexConversationAttachmentName {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '图片' }
    try { return [IO.Path]::GetFileName($Path) } catch { return '图片' }
}

function Save-CodexConversationImage {
    param([Drawing.Image]$Image)
    if ($null -eq $Image) { return '' }
    Ensure-DataDirectories
    $directory=Get-CodexConversationAttachmentDirectory
    $fileName=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')+'-'+([guid]::NewGuid().ToString('N'))+'.png'
    $path=Join-Path $directory $fileName
    $bitmap=$null
    try {
        $bitmap=[Drawing.Bitmap]$Image.Clone()
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
        return $path
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return ''
    } finally { if($null-ne$bitmap){$bitmap.Dispose()} }
}

function Add-CodexConversationPendingImage {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)-or-not[IO.File]::Exists($Path)){return $false}
    [void]$script:CodexConversationPendingImages.Add([pscustomobject]@{Id=([guid]::NewGuid().ToString());Path=$Path;Name=(Get-CodexConversationAttachmentName $Path);CreatedAt=Get-Date})
    Refresh-CodexConversationAttachmentPreview
    return $true
}

function Import-CodexConversationImageFile {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)-or-not[IO.File]::Exists($Path)){return $false}
    $image=$null
    try {
        $image=[Drawing.Image]::FromFile($Path)
        $saved=Save-CodexConversationImage $image
        if([string]::IsNullOrWhiteSpace($saved)){return $false}
        return Add-CodexConversationPendingImage $saved
    } catch { return $false }
    finally { if($null-ne$image){$image.Dispose()} }
}

function Paste-CodexConversationClipboardImage {
    if(-not[Windows.Forms.Clipboard]::ContainsImage()){
        Show-Message '剪贴板中没有可粘贴的图片。' '图片附件' ([Windows.Forms.MessageBoxIcon]::Information)
        return $false
    }
    $image=$null
    try {
        $image=[Windows.Forms.Clipboard]::GetImage()
        $path=Save-CodexConversationImage $image
        if([string]::IsNullOrWhiteSpace($path)){Show-Message '保存剪贴板图片失败。' '图片附件' ([Windows.Forms.MessageBoxIcon]::Warning);return $false}
        return Add-CodexConversationPendingImage $path
    } catch {
        Show-Message ('读取剪贴板图片失败：'+$_.Exception.Message) '图片附件' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    } finally { if($null-ne$image){$image.Dispose()} }
}

function Remove-CodexConversationPendingImage {
    param([string]$Id)
    for($index=$script:CodexConversationPendingImages.Count-1;$index-ge0;$index--){
        $item=$script:CodexConversationPendingImages[$index]
        if([string]$item.Id-eq$Id){
            $script:CodexConversationPendingImages.RemoveAt($index)
            $attachmentDirectory=(Get-CodexConversationAttachmentDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
            $path=[string]$item.Path
            if(-not[string]::IsNullOrWhiteSpace($path)-and$path.StartsWith($attachmentDirectory,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
            break
        }
    }
    Refresh-CodexConversationAttachmentPreview
}

function Clear-CodexConversationPendingImages {
    param([switch]$KeepFiles)
    if(-not$KeepFiles){
        $attachmentDirectory=(Get-CodexConversationAttachmentDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
        foreach($item in @($script:CodexConversationPendingImages)){
            $path=[string]$item.Path
            if(-not[string]::IsNullOrWhiteSpace($path)-and$path.StartsWith($attachmentDirectory,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
        }
    }
    $script:CodexConversationPendingImages.Clear()
    Refresh-CodexConversationAttachmentPreview
}

function Get-CodexConversationComposerMinimumHeight {
    $composer=$script:CodexConversationComposer
    if($null-eq$composer-or$composer.IsDisposed){return (ConvertTo-WorkflowDpiPixels 124 100)}
    $actionBottom=0
    foreach($button in @($script:CodexConversationSend,$script:CodexConversationAttachButton,$script:CodexConversationClearAttachmentsButton,$script:CodexConversationComposerExpandButton)){
        if($null-ne$button-and-not$button.IsDisposed){$actionBottom=[Math]::Max($actionBottom,$button.Bottom)}
    }
    $previewHeight=0
    if($null-ne$script:CodexConversationInputSurface-and$script:CodexConversationInputSurface.RowStyles.Count-gt1){$previewHeight=[int][Math]::Round($script:CodexConversationInputSurface.RowStyles[1].Height)}
    $textMinimum=ConvertTo-WorkflowDpiPixels 58 48
    if($null-ne$script:CodexConversationInput-and-not$script:CodexConversationInput.IsDisposed){$textMinimum=[Math]::Max($textMinimum,$script:CodexConversationInput.Font.Height*3)}
    $inputMinimum=$textMinimum+$previewHeight
    if($null-ne$script:CodexConversationInputSurface){$inputMinimum+=$script:CodexConversationInputSurface.Padding.Vertical}
    if($null-ne$script:CodexConversationInputFrame){$inputMinimum+=$script:CodexConversationInputFrame.Padding.Vertical}
    $contentMinimum=[Math]::Max($inputMinimum,$actionBottom+(ConvertTo-WorkflowDpiPixels 7 5))
    return [Math]::Max((ConvertTo-WorkflowDpiPixels 124 100),$composer.Padding.Vertical+$contentMinimum)
}

function Sync-CodexConversationComposerChildHeight {
    if($null-eq$script:CodexConversationComposerLayout-or$script:CodexConversationComposerLayout.IsDisposed){return}
    $contentHeight=[Math]::Max(1,$script:CodexConversationComposerLayout.ClientSize.Height)
    foreach($control in @($script:CodexConversationInputFrame,$script:CodexConversationActions)){
        if($null-ne$control-and-not$control.IsDisposed){$control.Top=0;$control.Height=$contentHeight}
    }
}

function Set-CodexConversationComposerHeight {
    param([int]$RequestedHeight=0,[switch]$FromDrag)
    if($null-eq$script:CodexConversationComposerRowStyle-or$null-eq$script:CodexConversationLayout-or$script:CodexConversationLayout.IsDisposed){return 0}
    $minimum=Get-CodexConversationComposerMinimumHeight
    $headerHeight=if($script:CodexConversationLayout.RowStyles.Count-gt0){[int][Math]::Round($script:CodexConversationLayout.RowStyles[0].Height)}else{ConvertTo-WorkflowDpiPixels 88 70}
    $messageMinimum=ConvertTo-WorkflowDpiPixels 170 130
    $maximum=[Math]::Max($minimum,$script:CodexConversationLayout.ClientSize.Height-$headerHeight-$messageMinimum)
    if($FromDrag){
        $script:CodexConversationComposerExpanded=$false
        $script:CodexConversationComposerRestoreHeight=0
        $script:CodexConversationComposerUserHeight=$RequestedHeight
    }
    if($RequestedHeight-gt0){$target=$RequestedHeight}
    elseif($script:CodexConversationComposerExpanded){$target=[Math]::Max($minimum,[int]($script:CodexConversationLayout.ClientSize.Height*0.46))}
    elseif($script:CodexConversationComposerUserHeight-gt0){$target=$script:CodexConversationComposerUserHeight}
    else{$target=$minimum}
    $target=[Math]::Max($minimum,[Math]::Min($maximum,[int]$target))
    if($FromDrag){$script:CodexConversationComposerUserHeight=$target}
    if([Math]::Abs($script:CodexConversationComposerRowStyle.Height-$target)-gt1){
        $script:CodexConversationComposerRowStyle.Height=$target
        if($null-ne$script:CodexConversationLayout-and-not$script:CodexConversationLayout.IsDisposed){$script:CodexConversationLayout.PerformLayout()}
        if($null-ne$script:CodexConversationComposer-and-not$script:CodexConversationComposer.IsDisposed){$script:CodexConversationComposer.PerformLayout()}
        if($null-ne$script:CodexConversationComposerLayout-and-not$script:CodexConversationComposerLayout.IsDisposed){$script:CodexConversationComposerLayout.PerformLayout()}
        Sync-CodexConversationComposerChildHeight
    }
    if($null-ne$script:CodexConversationComposerExpandButton){$script:CodexConversationComposerExpandButton.Text=if($script:CodexConversationComposerExpanded){'还原'}else{'展开'}}
    return $target
}

function Update-CodexConversationComposerHeight {
    [void](Set-CodexConversationComposerHeight)
}

function Toggle-CodexConversationComposerExpanded {
    if($null-eq$script:CodexConversationComposerRowStyle){return}
    if($script:CodexConversationComposerExpanded){
        $script:CodexConversationComposerExpanded=$false
        $minimum=Get-CodexConversationComposerMinimumHeight
        $restore=[int]$script:CodexConversationComposerRestoreHeight
        $script:CodexConversationComposerUserHeight=if($restore-gt($minimum+2)){$restore}else{0}
        $script:CodexConversationComposerRestoreHeight=0
    }else{
        $script:CodexConversationComposerRestoreHeight=[int][Math]::Round($script:CodexConversationComposerRowStyle.Height)
        $script:CodexConversationComposerExpanded=$true
    }
    Update-CodexConversationComposerHeight
    if($null-ne$script:CodexConversationInput){[void]$script:CodexConversationInput.Focus()}
}

function Refresh-CodexConversationAttachmentPreview {
    $preview=$script:CodexConversationAttachmentPreview
    if($null-eq$preview-or$preview.IsDisposed){return}
    foreach($control in @($preview.Controls)){
        if($control-is[Windows.Forms.Panel]){foreach($child in @($control.Controls)){if($child-is[Windows.Forms.PictureBox]-and$null-ne$child.Image){$child.Image.Dispose()}}}
        $control.Dispose()
    }
    $preview.Controls.Clear()
    $cardWidth=ConvertTo-WorkflowDpiPixels 96 80;$cardHeight=ConvertTo-WorkflowDpiPixels 62 52;$removeSize=ConvertTo-WorkflowDpiPixels 18 16;$edge=ConvertTo-WorkflowDpiPixels 2 1
    $pictureWidth=[Math]::Max(48,$cardWidth-$removeSize-$edge*2);$pictureHeight=[Math]::Max(42,$cardHeight-$edge*2);$cardGap=ConvertTo-WorkflowDpiPixels 6 4
    foreach($item in @($script:CodexConversationPendingImages)){
        $card=New-Object Windows.Forms.Panel;$card.Size=New-Object Drawing.Size($cardWidth,$cardHeight);$card.Margin=New-Object Windows.Forms.Padding(0,0,$cardGap,0);$card.BackColor=[Drawing.Color]::FromArgb(226,232,240)
        $picture=New-Object Windows.Forms.PictureBox;$picture.Location=New-Object Drawing.Point($edge,$edge);$picture.Size=New-Object Drawing.Size($pictureWidth,$pictureHeight);$picture.SizeMode=[Windows.Forms.PictureBoxSizeMode]::Zoom;$picture.BackColor=[Drawing.Color]::White;$picture.Tag=[string]$item.Path
        try{$bytes=[IO.File]::ReadAllBytes([string]$item.Path);$stream=New-Object IO.MemoryStream(,$bytes);$source=[Drawing.Image]::FromStream($stream);$picture.Image=[Drawing.Bitmap]$source.Clone();$source.Dispose();$stream.Dispose()}catch{}
        $picture.Add_DoubleClick({param($sender,$e);$path=[string]$sender.Tag;if([IO.File]::Exists($path)){Start-Process -FilePath $path|Out-Null}})
        $remove=New-Object Windows.Forms.Button;$remove.Text='X';$remove.Size=New-Object Drawing.Size($removeSize,$removeSize);$remove.Location=New-Object Drawing.Point(($cardWidth-$removeSize-$edge),$edge);$remove.FlatStyle=[Windows.Forms.FlatStyle]::Flat;$remove.FlatAppearance.BorderSize=0;$remove.BackColor=[Drawing.Color]::White;$remove.Tag=[string]$item.Id;$remove.Add_Click({param($sender,$e);Remove-CodexConversationPendingImage ([string]$sender.Tag)})
        $card.Controls.Add($picture);$card.Controls.Add($remove);$preview.Controls.Add($card)
    }
    $count=$script:CodexConversationPendingImages.Count
    $preview.Visible=$count-gt0
    if($null-ne$script:CodexConversationInputSurface-and$script:CodexConversationInputSurface.RowStyles.Count-gt1){$script:CodexConversationInputSurface.RowStyles[1].Height=if($count-gt0){$cardHeight+(ConvertTo-WorkflowDpiPixels 6 4)}else{0}}
    if($null-ne$script:CodexConversationClearAttachmentsButton){$script:CodexConversationClearAttachmentsButton.Enabled=$count-gt0}
    if($null-ne$script:CodexConversationAttachButton){$script:CodexConversationAttachButton.Text=if($count-gt0){'粘贴图片 ('+$count+')'}else{'粘贴图片'}}
    if($null-ne$script:CodexConversationComposerLayoutHandler){& $script:CodexConversationComposerLayoutHandler}
    if($null-ne$script:CodexConversationComposer){$script:CodexConversationComposer.PerformLayout()}
    Update-CodexConversationComposerHeight
}

function Get-CodexConversationPromptWithImages {
    param([string]$Prompt,[object[]]$Images)
    $value=if($null-eq$Prompt){''}else{$Prompt.Trim()}
    $items=@($Images|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_.Path)})
    if($items.Count-eq0){return $value}
    if([string]::IsNullOrWhiteSpace($value)){$value='请查看并分析所附图片。'}
    $paths=@($items|ForEach-Object{'- '+[string]$_.Path})-join"`r`n"
    return $value+"`r`n`r`n附带图片（已通过 Codex --image 传入）：`r`n"+$paths
}

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append([char]'\', (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append([char]'\', $backslashes); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append([char]'\', ($backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Resolve-ConfiguredPath {
    param([string]$Path, [string]$Fallback = '')
    $resolved = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = $Fallback }
    $resolved = [string]$resolved
    $resolved = $resolved.Trim()
    if ($resolved.Length -ge 2 -and (($resolved[0] -eq '"' -and $resolved[$resolved.Length-1] -eq '"') -or ($resolved[0] -eq "'" -and $resolved[$resolved.Length-1] -eq "'"))) { $resolved = $resolved.Substring(1,$resolved.Length-2).Trim() }
    return $resolved
}

function Resolve-CodexWorkingDirectory {
    param([string]$Path,[string]$Fallback='')
    $resolved=Resolve-ConfiguredPath $Path $Fallback
    if([string]::IsNullOrWhiteSpace($resolved)){return ''}
    try{$resolved=[IO.Path]::GetFullPath($resolved)}catch{return ''}
    if(-not[IO.Directory]::Exists($resolved)){return ''}
    return $resolved
}

function New-CodexInteractiveResumeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CodexPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$Model = ''
    )
    $modelArgument = if ([string]::IsNullOrWhiteSpace($Model)) { '' } else { ' --model ' + (ConvertTo-NativeArgument $Model.Trim()) }
    return (ConvertTo-NativeArgument $CodexPath) + ' --yolo -C ' + (ConvertTo-NativeArgument $WorkingDirectory) + $modelArgument + ' resume ' + (ConvertTo-NativeArgument $SessionId)
}

function New-CodexExecResumeArguments {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Model = ''
    )
    $modelArgument = if ([string]::IsNullOrWhiteSpace($Model)) { '' } else { ' --model ' + (ConvertTo-NativeArgument $Model.Trim()) }
    return 'exec --yolo --skip-git-repo-check' + $modelArgument + ' resume ' + (ConvertTo-NativeArgument $SessionId) + ' ' + (ConvertTo-NativeArgument $Prompt)
}

function ConvertTo-CodexImageArguments {
    param([string[]]$ImagePaths = @())
    $parts=New-Object System.Collections.Generic.List[string]
    foreach($path in @($ImagePaths)){
        if([string]::IsNullOrWhiteSpace($path)-or-not[IO.File]::Exists($path)){continue}
        $parts.Add('-i '+(ConvertTo-NativeArgument $path))
    }
    if($parts.Count-eq0){return ''}
    return ' '+($parts -join ' ')
}

function New-ProjectCodexArguments {
    param(
        [string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$Model = '',
        [string[]]$ImagePaths = @()
    )
    $common = 'exec --yolo --skip-git-repo-check --json -o ' + (ConvertTo-NativeArgument $OutputPath)
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $common += ' --model ' + (ConvertTo-NativeArgument $Model.Trim()) }
    $imageArguments=ConvertTo-CodexImageArguments $ImagePaths
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return $common + $imageArguments + ' -C ' + (ConvertTo-NativeArgument $WorkingDirectory) + ' ' + (ConvertTo-NativeArgument $Prompt)
    }
    return $common + ' resume' + $imageArguments + ' ' + (ConvertTo-NativeArgument $SessionId) + ' ' + (ConvertTo-NativeArgument $Prompt)
}

function Get-WorkflowAiSkillPath {
    $requiredFiles=@('SKILL.md','agents\openai.yaml','scripts\invoke-workflow-manager.ps1','references\api.md')
    $embeddedReady=@($requiredFiles|Where-Object{Test-Path -LiteralPath (Join-Path $script:EmbeddedWorkflowSkillPath $_)}).Count-eq$requiredFiles.Count
    if ($embeddedReady) { return $script:EmbeddedWorkflowSkillPath }
    $sourceReady=@($requiredFiles|Where-Object{Test-Path -LiteralPath (Join-Path $script:SourceWorkflowSkillPath $_)}).Count-eq$requiredFiles.Count
    if ($sourceReady) { return $script:SourceWorkflowSkillPath }
    return $script:EmbeddedWorkflowSkillPath
}

function Get-WorkflowAiPrompt {
    param([Parameter(Mandatory=$true)][string]$UserPrompt)
    $skillPath = Get-WorkflowAiSkillPath
    return @"
You are 使驾 AI, the dedicated workflow assistant for 使驾. This is an isolated persistent session; do not resume, edit, or inject messages into unrelated Codex sessions.

Read and follow the 使驾 workflow-manager skill at:
$skillPath\SKILL.md

The bundled API client is:
$skillPath\scripts\invoke-workflow-manager.ps1

使驾 API: http://127.0.0.1:5169 (localhost, no Authorization).
Dedicated working directory: $script:WorkflowAiDirectory

Always list 使驾 projects before project/workflow mutations. Use the sessions API to inspect historical session summaries, never modify Codex JSONL history directly, reuse projects with matching normalized directories, and use only real session IDs returned by the API.

User request:
$($UserPrompt.Trim())
"@
}

function New-WorkflowAiCodexArguments {
    param([string]$SessionId, [string]$Prompt, [string]$OutputPath, [string[]]$ImagePaths = @())
    $common = '--yolo --skip-git-repo-check --json -o ' + (ConvertTo-NativeArgument $OutputPath) + ' '
    $imageArguments=ConvertTo-CodexImageArguments $ImagePaths
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return 'exec ' + $common + $imageArguments + ' -C ' + (ConvertTo-NativeArgument $script:WorkflowAiDirectory) + ' ' + (ConvertTo-NativeArgument $Prompt)
    }
    return 'exec ' + $common + 'resume' + $imageArguments + ' ' + (ConvertTo-NativeArgument $SessionId) + ' ' + (ConvertTo-NativeArgument $Prompt)
}

function Get-CodexJsonSessionId {
    param([string]$JsonLines)
    foreach($line in @($JsonLines -split "`r?`n")){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        try{
            $event=$line|ConvertFrom-Json
            foreach($name in @('thread_id','session_id')){
                if($null-ne$event.PSObject.Properties[$name] -and -not[string]::IsNullOrWhiteSpace([string]$event.$name)){return [string]$event.$name}
            }
        }catch{}
    }
    return ''
}

function Set-ProjectEditorFromCodexSession {
    param($Session, $NameBox, $DirectoryBox, $SessionBox)
    if ($null -eq $Session) { return }
    $sessionDirectory = [string]$Session.working_directory
    if (-not [string]::IsNullOrWhiteSpace($sessionDirectory)) { $DirectoryBox.Text = $sessionDirectory }
    $SessionBox.Text = [string]$Session.session_id
    if ([string]::IsNullOrWhiteSpace($NameBox.Text)) {
        $suggestedName = if ([string]::IsNullOrWhiteSpace($sessionDirectory)) { '' } else { Split-Path -Leaf $sessionDirectory }
        if ([string]::IsNullOrWhiteSpace($suggestedName)) { $suggestedName = [string]$Session.title }
        if (-not [string]::IsNullOrWhiteSpace($suggestedName)) { $NameBox.Text = $suggestedName.Trim() }
    }
}

function Test-CodexForkProcessRunning {
    param($Process)
    if ($null -eq $Process) { return $false }
    if ($Process -is [WorkflowConPtyProcess]) { return [bool]$Process.IsRunning }
    try { return -not [bool]$Process.HasExited } catch { return $false }
}

function Get-CodexForkProcessOutput {
    param($ForkOperation = $null)
    if ($null -ne $ForkOperation) {
        $parts=New-Object System.Collections.Generic.List[string]
        foreach($capture in @((Get-UiConfigValue $ForkOperation 'OutputCapture' $null),(Get-UiConfigValue $ForkOperation 'ErrorCapture' $null))){
            if($null -ne $capture){try{[void]$parts.Add([string]$capture.GetText())}catch{}}
        }
        return ($parts -join "`r`n")
    }
    if ($null -eq $ForkOperation) { return '' }
    $Process=Get-UiConfigValue $ForkOperation 'Process' $null
    if ($Process -is [WorkflowConPtyProcess]) { try { return [string]$Process.GetOutputSnapshot() } catch { return '' } }
    return ''
}

function Start-CodexSessionForkProcess {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$FallbackWorkingDirectory = ''
    )
    $codexPath = Resolve-ConfiguredPath ([string](Get-UiConfigValue $script:GlobalSettings 'CodexPath' ''))
    if ([string]::IsNullOrWhiteSpace($codexPath)) { throw '全局 Codex 路径为空。' }
    if (-not [IO.File]::Exists($codexPath)) { throw ('Codex 路径不存在：' + $codexPath) }
    $requestedDirectory = Resolve-ConfiguredPath $WorkingDirectory
    $directory = if (-not [string]::IsNullOrWhiteSpace($requestedDirectory) -and [IO.Directory]::Exists($requestedDirectory)) { $requestedDirectory } else { Resolve-ConfiguredPath $FallbackWorkingDirectory }
    if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Directory]::Exists($directory)) { throw ('Fork 工作目录不存在：' + $requestedDirectory) }
    if ($directory -ne $requestedDirectory) { Write-WorkflowLog ('Fork 历史工作目录不存在，已回退到项目目录：' + $directory) 'WARN' }
    # An explicit empty prompt makes Codex persist the fork metadata even when the parent session was created by exec.
    $arguments = '--headless -- ' + (ConvertTo-NativeArgument $codexPath) + ' fork ' + (ConvertTo-NativeArgument $SessionId.Trim()) + ' ' + (ConvertTo-NativeArgument '')
    $hostPath=Join-Path $env:WINDIR 'System32\conhost.exe'
    if(-not[IO.File]::Exists($hostPath)){throw ('系统找不到 conhost.exe：'+$hostPath)}
    $process=New-Object Diagnostics.Process
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$hostPath;$info.Arguments=$arguments;$info.WorkingDirectory=$directory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process.StartInfo=$info
    if(-not$process.Start()){$process.Dispose();throw '无法启动 Codex Fork 终端。'}
    $outputCapture=New-Object WorkflowProcessStreamCapture($process.StandardOutput,32768)
    $errorCapture=New-Object WorkflowProcessStreamCapture($process.StandardError,16384)
    Write-WorkflowLog ('项目配置 Fork 已启动：codex fork ' + $SessionId + '；工作目录：' + $directory + '；PID：' + [string]$process.Id) 'INFO'
    return [pscustomobject]@{
        Process = $process
        ProcessId = [int]$process.Id
        SessionId = $SessionId.Trim()
        WorkingDirectory = $directory
        Arguments = $arguments
        StartedAt = Get-Date
        TrustInputSent = $false
        OutputCapture = $outputCapture
        ErrorCapture = $errorCapture
    }
}

function Stop-CodexSessionForkProcess {
    param($ForkOperation)
    if ($null -eq $ForkOperation) { return }
    $process = $ForkOperation.Process
    if ($null -eq $process) { return }
    try {
        $processId = [int](Get-UiConfigValue $ForkOperation 'ProcessId' 0)
        if (Test-CodexForkProcessRunning $process) {
            Write-WorkflowLog ('停止项目配置 Fork 进程：PID：' + [string]$processId + '；源会话：' + [string]$ForkOperation.SessionId) 'DEBUG'
            if ($processId -gt 0) { Stop-WorkflowProcessTree $processId }
        }
    } catch {
        Write-WorkflowLog ('停止项目配置 Fork 进程失败：' + $_.Exception.Message) 'ERROR'
        try { if ($process -is [WorkflowConPtyProcess]) { $process.Terminate(1) } else { $process.Kill() } } catch { }
    } finally {
        foreach($capture in @((Get-UiConfigValue $ForkOperation 'OutputCapture' $null),(Get-UiConfigValue $ForkOperation 'ErrorCapture' $null))){if($null-ne$capture){try{$capture.Dispose()}catch{}}}
        try { $process.Dispose() } catch { }
        $ForkOperation.Process = $null
    }
}

function Show-ProjectEditor {
    param($Project = $null)
    $editing = $null -ne $Project
    $form = New-Object Windows.Forms.Form
    Set-WorkflowFormScaling $form
    $form.Text = if ($editing) { '项目配置' } else { '新建项目' }
    $form.StartPosition = 'CenterParent'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(920,820); $form.Font = New-UiFont 9; Set-WorkflowWindowIcon $form
    Add-UiLabel $form '项目名称' 24 30 110 24 | Out-Null
    $nameBox = New-Object Windows.Forms.TextBox; $nameBox.Location = New-Object Drawing.Point(142,27); $nameBox.Size = New-Object Drawing.Size(754,28); $nameBox.Text = if($editing){[string]$Project.Name}else{''}; $form.Controls.Add($nameBox)
    Add-UiLabel $form '默认工作目录' 24 78 110 24 | Out-Null
    $directoryBox = New-Object Windows.Forms.TextBox; $directoryBox.Location = New-Object Drawing.Point(142,75); $directoryBox.Size = New-Object Drawing.Size(702,28); $directoryBox.Text = if($editing){[string]$Project.DefaultWorkingDirectory}else{[Environment]::GetFolderPath('MyDocuments')}; $form.Controls.Add($directoryBox)
    $browse = Add-UiButton $form '...' 852 75 44 28
    $browse.Add_Click({ $dialog = New-Object Windows.Forms.FolderBrowserDialog; $dialog.SelectedPath = Resolve-ConfiguredPath $directoryBox.Text; if($dialog.ShowDialog($form) -eq 'OK'){$directoryBox.Text=$dialog.SelectedPath}; $dialog.Dispose() })
    $sessionTitle=Add-UiLabel $form '项目 Codex 会话' 24 122 180 26; $sessionTitle.Font=New-UiFont 10 ([Drawing.FontStyle]::Bold)
    Add-UiLabel $form '第一行是默认主会话；新项目可以不配置，首次发送消息后会自动创建。' 206 124 690 24 -Muted | Out-Null
    $sessionConfigGrid=New-Object Windows.Forms.DataGridView
    $sessionConfigGrid.Location=New-Object Drawing.Point(24,154);$sessionConfigGrid.Size=New-Object Drawing.Size(872,220)
    $sessionConfigGrid.AllowUserToAddRows=$false;$sessionConfigGrid.AllowUserToDeleteRows=$false;$sessionConfigGrid.AllowUserToResizeRows=$false;$sessionConfigGrid.MultiSelect=$false;$sessionConfigGrid.SelectionMode='FullRowSelect';$sessionConfigGrid.AutoGenerateColumns=$false;$sessionConfigGrid.RowHeadersVisible=$false;$sessionConfigGrid.RowTemplate.Height=32
    $typeColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn;$typeColumn.Name='Type';$typeColumn.HeaderText='类型';$typeColumn.Width=88;$typeColumn.ReadOnly=$true;[void]$sessionConfigGrid.Columns.Add($typeColumn)
    $configIdColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn;$configIdColumn.Name='SessionId';$configIdColumn.HeaderText='Codex 会话 ID';$configIdColumn.AutoSizeMode='Fill';$configIdColumn.FillWeight=42;[void]$sessionConfigGrid.Columns.Add($configIdColumn)
    $configModelColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn;$configModelColumn.Name='Model';$configModelColumn.HeaderText='Codex 模型';$configModelColumn.Width=170;[void]$sessionConfigGrid.Columns.Add($configModelColumn)
    $configDescriptionColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn;$configDescriptionColumn.Name='Description';$configDescriptionColumn.HeaderText='会话描述';$configDescriptionColumn.AutoSizeMode='Fill';$configDescriptionColumn.FillWeight=30;[void]$sessionConfigGrid.Columns.Add($configDescriptionColumn)
    $form.Controls.Add($sessionConfigGrid)
    $refreshSessionTypes={
        for($index=0;$index-lt$sessionConfigGrid.Rows.Count;$index++){$row=Get-UiIndexedItemSafe $sessionConfigGrid.Rows $index;if($null-ne$row){$row.Cells['Type'].Value=if($index-eq0){'主会话'}else{'辅助会话'}}}
    }
    $addSessionRow={
        param([string]$SessionId='',[string]$Model='',[string]$Description='')
        $rowIndex=$sessionConfigGrid.Rows.Add('',[string]$SessionId,[string]$Model,[string]$Description)
        & $refreshSessionTypes
        $row=Get-UiIndexedItemSafe $sessionConfigGrid.Rows $rowIndex
        if($null-ne$row){$row.Selected=$true;$sessionConfigGrid.CurrentCell=$row.Cells['SessionId']}
        return $row
    }
    if($editing){foreach($entry in @(Get-ProjectCodexSessions $Project)){& $addSessionRow ([string]$entry.SessionId) ([string]$entry.CodexModel) ([string]$entry.Description)|Out-Null}}
    $addSession=Add-UiButton $form '添加会话' 24 384 104 30 'Primary'
    $removeSession=Add-UiButton $form '删除选中' 136 384 104 30 'Danger'
    Add-UiLabel $form '模型留空时使用 Codex 默认模型；删除第一行后，下一行会自动成为主会话。' 254 388 642 24 -Muted | Out-Null
    $addSession.Add_Click({& $addSessionRow '' '' '无描述'|Out-Null})
    $removeSession.Add_Click({$selectedRow=Get-UiSelectedItemSafe $sessionConfigGrid.SelectedRows;if($null-ne$selectedRow){$sessionConfigGrid.Rows.Remove($selectedRow);& $refreshSessionTypes}})
    Add-UiLabel $form '最近 Codex 会话' 24 450 150 24 | Out-Null
    $refreshSessions = Add-UiButton $form '刷新' 692 444 76 30
    $selectSession = Add-UiButton $form '填入选中会话' 776 444 120 30 'Primary'
    $sessionGrid = New-Object Windows.Forms.DataGridView
    $sessionGrid.Location = New-Object Drawing.Point(24,480); $sessionGrid.Size = New-Object Drawing.Size(872,250)
    $sessionGrid.ReadOnly=$true; $sessionGrid.AllowUserToAddRows=$false; $sessionGrid.AllowUserToDeleteRows=$false; $sessionGrid.AllowUserToResizeRows=$false
    $sessionGrid.MultiSelect=$false; $sessionGrid.SelectionMode='FullRowSelect'; $sessionGrid.AutoGenerateColumns=$false; $sessionGrid.RowHeadersVisible=$false;$sessionGrid.RowTemplate.Height=30
    $timeColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $timeColumn.Name='Time'; $timeColumn.HeaderText='时间'; $timeColumn.Width=132; [void]$sessionGrid.Columns.Add($timeColumn)
    $titleColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $titleColumn.Name='Title'; $titleColumn.HeaderText='会话摘要'; $titleColumn.Width=220; [void]$sessionGrid.Columns.Add($titleColumn)
    $directoryColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $directoryColumn.Name='Directory'; $directoryColumn.HeaderText='工作目录'; $directoryColumn.AutoSizeMode='Fill'; [void]$sessionGrid.Columns.Add($directoryColumn)
    $idColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $idColumn.Name='SessionId'; $idColumn.HeaderText='Session ID'; $idColumn.Width=270; [void]$sessionGrid.Columns.Add($idColumn)
    $form.Controls.Add($sessionGrid)
    $sessionRecords = @()
    $forkState=[pscustomobject]@{Active=$false;Process=$null;ProcessId=0;SourceSessionId='';WorkingDirectory='';BeforeSessionIds=@{};StartedAt=[datetime]::MinValue;TrustInputSent=$false}
    $forkTimer=New-Object Windows.Forms.Timer;$forkTimer.Interval=1000
    $forkStatusLabel=Add-UiLabel $form '右键最近会话可 Fork 新会话。' 24 738 650 28 -Muted
    $sessionGridContextMenu=New-Object Windows.Forms.ContextMenuStrip;$sessionGridContextMenu.ShowImageMargin=$false
    $forkSessionItem=New-Object Windows.Forms.ToolStripMenuItem 'Fork 新会话'
    $forkSessionItem.ToolTipText='基于选中的历史会话创建一个新的 Codex 会话'
    [void]$sessionGridContextMenu.Items.Add($forkSessionItem)
    $sessionGrid.ContextMenuStrip=$sessionGridContextMenu
    $sessionGrid.Add_CellMouseDown({
        param($sender,$e)
        if($e.Button -ne [Windows.Forms.MouseButtons]::Right -or $e.RowIndex -lt 0){return}
        $sender.ClearSelection()
        $row=Get-UiIndexedItemSafe $sender.Rows $e.RowIndex
        if($null -ne $row){$row.Selected=$true;$cell=Get-UiIndexedItemSafe $row.Cells 0;if($null -ne $cell){$sender.CurrentCell=$cell}}
    })
    $loadSessions = {
        param([bool]$Refresh)
        $sessionGrid.Rows.Clear()
        $script:CodexSessionCacheAt = if($Refresh){[datetime]::MinValue}else{$script:CodexSessionCacheAt}
        $sessionRecords = @(Get-CodexSessionSummaries '' 100 -Refresh:$Refresh)
        foreach($session in $sessionRecords){
            $displayTime=[string]$session.time; try{$displayTime=([datetime]$session.time).ToLocalTime().ToString('yyyy-MM-dd HH:mm')}catch{}
            $index=$sessionGrid.Rows.Add($displayTime,[string]$session.title,[string]$session.working_directory,[string]$session.session_id)
             $row=Get-UiIndexedItemSafe $sessionGrid.Rows $index
             if($null-ne$row){$row.Tag=$session;if($editing -and @((Get-ProjectCodexSessions $Project)|Where-Object{[string]$_.SessionId-eq[string]$session.session_id}).Count-gt0){$row.Selected=$true;$firstCell=Get-UiIndexedItemSafe $row.Cells 0;if($null-ne$firstCell){$sessionGrid.CurrentCell=$firstCell}}}
         }
         return @($sessionRecords)
     }
    $sessionGridContextMenu.Add_Opening({
        param($sender,$e)
        $selectedRow=Get-UiSelectedItemSafe $sessionGrid.SelectedRows
        $selected=if($null -ne $selectedRow){$selectedRow.Tag}else{$null}
        $canFork=$null -ne $selected -and -not [string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $selected 'session_id' '')) -and -not $forkState.Active
        $forkSessionItem.Enabled=$canFork
        if($forkState.Active){$forkSessionItem.Text='Fork 进行中'}else{$forkSessionItem.Text='Fork 新会话'}
        if(-not $canFork -and $null -eq $selected){$e.Cancel=$true}
    })
    $forkTimer.Add_Tick({
        if(-not $forkState.Active){$forkTimer.Stop();return}
        $elapsed=((Get-Date)-$forkState.StartedAt).TotalSeconds
        try{
            $currentSessions=@(& $loadSessions $true)
            if($null -ne $forkState.Process -and -not $forkState.TrustInputSent){
                $forkOutput=Get-CodexForkProcessOutput $forkState
                if($forkOutput -match '(?i)Do you trust|Yes, continue|trust the contents|信任.*目录|继续'){
                    try{$forkState.Process.StandardInput.Write("1`r`n");$forkState.Process.StandardInput.Flush();$forkState.TrustInputSent=$true;Write-WorkflowLog '项目配置 Fork 已自动确认信任工作目录。' 'INFO'}catch{Write-WorkflowLog ('项目配置 Fork 自动确认失败：'+$_.Exception.Message) 'WARN'}
                }
            }
            $directoryKey=ConvertTo-NormalizedDirectoryKey ([string]$forkState.WorkingDirectory)
            $matches=@($currentSessions|Where-Object{
                $candidateId=[string](Get-UiConfigValue $_ 'session_id' '')
                $parentId=[string](Get-UiConfigValue $_ 'forked_from_id' '')
                $candidateDirectory=ConvertTo-NormalizedDirectoryKey ([string](Get-UiConfigValue $_ 'working_directory' ''))
                -not [string]::IsNullOrWhiteSpace($candidateId) -and $candidateId -ne [string]$forkState.SourceSessionId -and -not $forkState.BeforeSessionIds.ContainsKey($candidateId.ToLowerInvariant()) -and $parentId -eq [string]$forkState.SourceSessionId -and $candidateDirectory -eq $directoryKey
            }|Sort-Object @{Expression={try{[datetime]$_.last_write_time}catch{[datetime]::MinValue}};Descending=$true})
            if($matches.Count -gt 0){
                $found=$matches[0]
                $forkTimer.Stop()
                Stop-CodexSessionForkProcess $forkState
                $forkState.Active=$false
                $newId=[string]$found.session_id
                $existing=@($sessionConfigGrid.Rows|Where-Object{[string]$_.Cells['SessionId'].Value -eq $newId}|Select-Object -First 1)
                if($existing.Count -eq 0){
                    $sourceConfig=@(Get-ProjectCodexSessions $Project|Where-Object{[string]$_.SessionId -eq [string]$forkState.SourceSessionId}|Select-Object -First 1)
                    $model=if($sourceConfig.Count -gt 0){[string]$sourceConfig[0].CodexModel}else{''}
                    $description=[string](Get-UiConfigValue $found 'title' '')
                    if([string]::IsNullOrWhiteSpace($description)){$description='Fork 会话 '+$newId.Substring(0,[Math]::Min(8,$newId.Length))}
                    [void](& $addSessionRow $newId $model $description.Trim())
                }
                $forkStatusLabel.Text='Fork 已完成，已新增会话：'+$newId
                Write-WorkflowLog ('项目配置 Fork 已识别新会话：'+$newId+'；forked_from_id：'+[string]$forkState.SourceSessionId+'；工作目录：'+[string]$forkState.WorkingDirectory) 'INFO'
                return
            }
            if($elapsed -ge 120){
                $forkTimer.Stop();Stop-CodexSessionForkProcess $forkState;$forkState.Active=$false;$forkStatusLabel.Text='Fork 超时，未找到新的会话文件。';Write-WorkflowLog ('项目配置 Fork 超时：源会话：'+[string]$forkState.SourceSessionId) 'ERROR';return
            }
            if($null -ne $forkState.Process){
                if(-not (Test-CodexForkProcessRunning $forkState.Process)){$forkTimer.Stop();Stop-CodexSessionForkProcess $forkState;$forkState.Active=$false;$forkStatusLabel.Text='Fork 进程已结束，但未识别到新的会话。';Write-WorkflowLog ('项目配置 Fork 进程已结束但未找到新会话：源会话：'+[string]$forkState.SourceSessionId) 'WARN';return}
            }
            $forkStatusLabel.Text='正在 Fork 新会话… 已等待 '+([int]$elapsed)+' 秒'
        }catch{
            Write-WorkflowLog ('项目配置 Fork 轮询失败：'+$_.Exception.Message) 'ERROR'
            if($elapsed -ge 120){$forkTimer.Stop();Stop-CodexSessionForkProcess $forkState;$forkState.Active=$false;$forkStatusLabel.Text='Fork 失败：'+$_.Exception.Message}
        }
    })
    $forkSessionItem.Add_Click({
        if($forkState.Active){return}
        $selectedRow=Get-UiSelectedItemSafe $sessionGrid.SelectedRows
        $selected=if($null -ne $selectedRow){$selectedRow.Tag}else{$null}
        $sourceId=[string](Get-UiConfigValue $selected 'session_id' '')
        $directory=[string](Get-UiConfigValue $selected 'working_directory' '')
        $projectDirectory=if($null -ne $Project){[string](Get-UiConfigValue $Project 'DefaultWorkingDirectory' '')}else{''}
        if($null -eq $selected -or [string]::IsNullOrWhiteSpace($sourceId)){Write-WorkflowLog '项目配置 Fork 请求无有效会话。' 'WARN';return}
        try{
            $before=@(& $loadSessions $true)
            $forkState.BeforeSessionIds=@{}
            foreach($item in $before){$beforeId=[string](Get-UiConfigValue $item 'session_id' '');if(-not [string]::IsNullOrWhiteSpace($beforeId)){$forkState.BeforeSessionIds[$beforeId.ToLowerInvariant()]=$true}}
            $forkState.SourceSessionId=$sourceId;$forkState.WorkingDirectory=$directory;$forkState.StartedAt=Get-Date;$forkState.Active=$true;$forkState.TrustInputSent=$false
            $forkStatusLabel.Text='正在启动 Fork…'
            $forkState.Process=Start-CodexSessionForkProcess $sourceId $directory $projectDirectory
            Write-WorkflowLog ('项目配置 Fork 开始轮询：源会话：'+$sourceId+'；工作目录：'+$directory) 'DEBUG'
            $forkTimer.Start()
        }catch{
            Stop-CodexSessionForkProcess $forkState;$forkState.Active=$false;$forkTimer.Stop();$forkStatusLabel.Text='Fork 启动失败：'+$_.Exception.Message;Write-WorkflowLog ('项目配置 Fork 启动失败：'+$_.Exception.Message) 'ERROR';Show-Message ('无法 Fork 会话：'+$_.Exception.Message) '项目配置' ([Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $applySelectedSession = {
        if($sessionGrid.SelectedRows.Count -eq 0){Show-Message '请先选择一个 Codex 会话。' '项目配置' ([Windows.Forms.MessageBoxIcon]::Information);return}
        $selectedRow=Get-UiSelectedItemSafe $sessionGrid.SelectedRows;if($null-eq$selectedRow){return};$selected=$selectedRow.Tag;if($null-eq$selected){return}
        $selectedDirectory=[string]$selected.working_directory;if(-not[string]::IsNullOrWhiteSpace($selectedDirectory)){$directoryBox.Text=$selectedDirectory}
        if([string]::IsNullOrWhiteSpace($nameBox.Text)){$suggestedName=if([string]::IsNullOrWhiteSpace($selectedDirectory)){[string]$selected.title}else{Split-Path -Leaf $selectedDirectory};if(-not[string]::IsNullOrWhiteSpace($suggestedName)){$nameBox.Text=$suggestedName.Trim()}}
        $selectedId=[string]$selected.session_id
        $targetRow=@($sessionConfigGrid.Rows|Where-Object{[string]$_.Cells['SessionId'].Value-eq$selectedId}|Select-Object -First 1)
        if($targetRow.Count-eq0){$row=Get-UiSelectedItemSafe $sessionConfigGrid.SelectedRows;if($null-eq$row){$row=& $addSessionRow}}
        else{$row=Get-UiIndexedItemSafe $targetRow 0}
        if($null-eq$row){return}
        $description=[string]$selected.title;if([string]::IsNullOrWhiteSpace($description)){$description='无描述'}
        $row.Cells['SessionId'].Value=$selectedId;$row.Cells['Description'].Value=$description.Trim();$row.Selected=$true;$sessionConfigGrid.CurrentCell=$row.Cells['SessionId'];& $refreshSessionTypes
    }
    $refreshSessions.Add_Click({[void](& $loadSessions $true)}); $selectSession.Add_Click({[void](& $applySelectedSession)}); $sessionGrid.Add_CellDoubleClick({[void](& $applySelectedSession)})
    $forkStatusLabel.Text='选择历史会话会填入当前配置行；右键最近会话可 Fork 新会话。'
    $save = Add-UiButton $form '保存项目' 764 770 132 36 'Primary'; $cancel = Add-UiButton $form '取消' 656 770 96 36; $cancel.DialogResult='Cancel'; $form.CancelButton=$cancel
    $resultProject = $null
    $save.Add_Click({
        if([string]::IsNullOrWhiteSpace($nameBox.Text)){Show-Message '项目名称不能为空。' '项目配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
        $directory = Resolve-ConfiguredPath $directoryBox.Text
        if([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Directory]::Exists($directory)){Show-Message '默认工作目录不存在。' '项目配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
        $sessionConfigGrid.EndEdit()
        $configuredSessions=New-Object System.Collections.ArrayList;$seenSessionIds=@{}
        foreach($row in @($sessionConfigGrid.Rows)){
            $configuredId=([string]$row.Cells['SessionId'].Value).Trim();$configuredModel=([string]$row.Cells['Model'].Value).Trim();$configuredDescription=([string]$row.Cells['Description'].Value).Trim()
            if([string]::IsNullOrWhiteSpace($configuredId)-and[string]::IsNullOrWhiteSpace($configuredModel)-and[string]::IsNullOrWhiteSpace($configuredDescription)){continue}
            if(-not[string]::IsNullOrWhiteSpace($configuredId)){
                $duplicateKey=$configuredId.ToLowerInvariant();if($seenSessionIds.ContainsKey($duplicateKey)){Show-Message ('Codex 会话 ID 重复：'+$configuredId) '项目配置' ([Windows.Forms.MessageBoxIcon]::Warning);return};$seenSessionIds[$duplicateKey]=$true
            }
            if([string]::IsNullOrWhiteSpace($configuredDescription)){$configuredDescription='无描述'}
            [void]$configuredSessions.Add([pscustomobject]@{SessionId=$configuredId;CodexModel=$configuredModel;Description=$configuredDescription})
        }
        $target = if ($editing) { $Project } else { New-Project }
        $target.Name=$nameBox.Text.Trim(); $target.DefaultWorkingDirectory=$directoryBox.Text.Trim();Set-ProjectCodexSessions $target @($configuredSessions);$target.UpdatedAt=(Get-Date).ToString('o')
        $script:ProjectEditorResult=$target; $form.DialogResult='OK'; $form.Close()
    })
    $form.Add_FormClosed({
        $forkTimer.Stop()
        if($forkState.Active -or $null -ne $forkState.Process){Stop-CodexSessionForkProcess $forkState;$forkState.Active=$false}
        try{$forkTimer.Dispose()}catch{}
        try{$sessionGridContextMenu.Dispose()}catch{}
    })
    Apply-UiTheme $form; [void](& $loadSessions $false); $script:ProjectEditorResult=$null
    try{if($form.ShowDialog($script:MainForm) -eq 'OK'){$resultProject=$script:ProjectEditorResult}}
    finally{if($null-ne$form-and-not$form.IsDisposed){$form.Dispose()}}
    $script:ProjectEditorResult=$null; return $resultProject
}

function Show-GlobalSettingsEditor {
    $form = New-Object Windows.Forms.Form
    Set-WorkflowFormScaling $form
    $form.Text='全局配置'; $form.StartPosition='CenterParent'; $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.MinimizeBox=$false
    $form.ClientSize=New-Object Drawing.Size(650,760); $form.Font=New-UiFont 9; Set-WorkflowWindowIcon $form
    Add-UiLabel $form 'Codex 路径' 24 34 110 24 | Out-Null
    $codexBox=New-Object Windows.Forms.TextBox; $codexBox.Location=New-Object Drawing.Point(142,31); $codexBox.Size=New-Object Drawing.Size(430,28); $codexBox.Text=[string]$script:GlobalSettings.CodexPath; $form.Controls.Add($codexBox)
    $browseCodex=Add-UiButton $form '...' 580 31 40 28
    Add-UiLabel $form 'VS Code 路径' 24 84 110 24 | Out-Null
    $vscodeBox=New-Object Windows.Forms.TextBox; $vscodeBox.Location=New-Object Drawing.Point(142,81); $vscodeBox.Size=New-Object Drawing.Size(430,28); $vscodeBox.Text=[string]$script:GlobalSettings.VSCodePath; $form.Controls.Add($vscodeBox)
    $browseVSCode=Add-UiButton $form '...' 580 81 40 28
    Add-UiLabel $form '使驾 AI 会话' 24 134 110 24 | Out-Null
    $workflowAiSessionBox=New-Object Windows.Forms.TextBox; $workflowAiSessionBox.Location=New-Object Drawing.Point(142,131); $workflowAiSessionBox.Size=New-Object Drawing.Size(350,28); $workflowAiSessionBox.ReadOnly=$true; $workflowAiSessionBox.Text=[string]$script:GlobalSettings.WorkflowAiSessionId; $form.Controls.Add($workflowAiSessionBox)
    $resetWorkflowAi=Add-UiButton $form '重置会话' 500 131 120 28 'Danger'
    Add-UiLabel $form '代码/文档打开器' 24 184 110 24 | Out-Null
    $documentEditorBox=New-Object Windows.Forms.TextBox; $documentEditorBox.Location=New-Object Drawing.Point(142,181); $documentEditorBox.Size=New-Object Drawing.Size(430,28); $documentEditorBox.Text=[string](Get-UiConfigValue $script:GlobalSettings 'DocumentEditorPath' ''); $form.Controls.Add($documentEditorBox)
    $browseDocumentEditor=Add-UiButton $form '...' 580 181 40 28
    Add-UiLabel $form '用于会话中的代码、文本和文档链接；留空时首次打开链接会询问，未选择则使用记事本。' 142 218 478 32 -Muted | Out-Null
    Add-UiLabel $form 'Python 虚拟环境解释器' 24 270 110 24 | Out-Null
    $pythonInterpreterBox=New-Object Windows.Forms.TextBox; $pythonInterpreterBox.Location=New-Object Drawing.Point(142,267); $pythonInterpreterBox.Size=New-Object Drawing.Size(430,28); $pythonInterpreterBox.Text=[string](Get-UiConfigValue $script:GlobalSettings 'PythonInterpreterPath' ''); $form.Controls.Add($pythonInterpreterBox)
    $browsePython=Add-UiButton $form '...' 580 267 40 28
    Add-UiLabel $form '可选：选择虚拟环境中的 python.exe；留空时使用系统 PATH 中的 python.exe。' 142 302 478 30 -Muted | Out-Null
    Add-UiLabel $form 'Web 服务' 24 350 110 24 | Out-Null
    $webEnabledCheck=New-Object Windows.Forms.CheckBox; $webEnabledCheck.Location=New-Object Drawing.Point(142,348); $webEnabledCheck.Size=New-Object Drawing.Size(120,28); $webEnabledCheck.Text='启用 Web'; $webEnabledCheck.Checked=[bool](Get-UiConfigValue $script:GlobalSettings 'WebEnabled' $false); $form.Controls.Add($webEnabledCheck)
    Add-UiLabel $form '访问码' 280 350 70 24 | Out-Null
    $webAccessCodeBox=New-Object Windows.Forms.TextBox; $webAccessCodeBox.Location=New-Object Drawing.Point(348,347); $webAccessCodeBox.Size=New-Object Drawing.Size(272,28); $webAccessCodeBox.UseSystemPasswordChar=$true; $webAccessCodeBox.Text=[string](Get-UiConfigValue $script:GlobalSettings 'WebAccessCode' ''); $form.Controls.Add($webAccessCodeBox)
    Add-UiLabel $form 'Web 端口' 24 392 110 24 | Out-Null
    $webPortBox=New-Object Windows.Forms.NumericUpDown; $webPortBox.Location=New-Object Drawing.Point(142,389); $webPortBox.Size=New-Object Drawing.Size(150,28); $webPortBox.Minimum=1024; $webPortBox.Maximum=65535; $webPortBox.Value=[decimal]([int](Get-UiConfigValue $script:GlobalSettings 'WebPort' 5170)); $form.Controls.Add($webPortBox)
    Add-UiLabel $form '启用后监听 0.0.0.0，访问码至少建议 8 位；默认端口 5170。' 310 392 310 30 -Muted | Out-Null
    $colorDivider=New-Object Windows.Forms.Panel;$colorDivider.Location=New-Object Drawing.Point(24,436);$colorDivider.Size=New-Object Drawing.Size(596,1);$colorDivider.BackColor=[Drawing.Color]::FromArgb(226,232,240);$form.Controls.Add($colorDivider)
    $colorTitle=Add-UiLabel $form '会话配色' 24 448 120 26;$colorTitle.Font=New-UiFont 10 ([Drawing.FontStyle]::Bold)
    Add-UiLabel $form '会话背景' 24 490 100 28 | Out-Null
    $surfaceColorButton=Add-UiButton $form '' 142 486 150 32
    Set-UiColorPickerButton $surfaceColorButton ([string]$script:GlobalSettings.ConversationSurfaceColor) ([Drawing.Color]::FromArgb(248,250,252))
    Add-UiLabel $form '发送气泡' 330 490 100 28 | Out-Null
    $userBubbleColorButton=Add-UiButton $form '' 448 486 172 32
    Set-UiColorPickerButton $userBubbleColorButton ([string]$script:GlobalSettings.ConversationUserBubbleColor) ([Drawing.Color]::FromArgb(219,234,254))
    Add-UiLabel $form '接收气泡' 24 534 100 28 | Out-Null
    $assistantBubbleColorButton=Add-UiButton $form '' 142 530 150 32
    Set-UiColorPickerButton $assistantBubbleColorButton ([string]$script:GlobalSettings.ConversationAssistantBubbleColor) ([Drawing.Color]::White)
    Add-UiLabel $form '输入框背景' 330 534 100 28 | Out-Null
    $inputBackgroundColorButton=Add-UiButton $form '' 448 530 172 32
    Set-UiColorPickerButton $inputBackgroundColorButton ([string]$script:GlobalSettings.ConversationInputBackgroundColor) ([Drawing.Color]::White)
    Add-UiLabel $form '输入文字' 24 578 100 28 | Out-Null
    $inputTextColorButton=Add-UiButton $form '' 142 574 150 32
    Set-UiColorPickerButton $inputTextColorButton ([string]$script:GlobalSettings.ConversationInputTextColor) ([Drawing.Color]::FromArgb(15,23,42))
     $resetColors=Add-UiButton $form '恢复默认配色' 448 574 172 32
     Add-UiLabel $form '颜色将保存到本机 settings.json，并立即应用于项目会话和使驾 AI。' 142 620 478 36 -Muted | Out-Null
     $memoryDiagnostics=Add-UiButton $form '内存诊断' 24 660 132 34
     Add-UiLabel $form '查看当前进程、CLR 堆、会话缓存和运行日志占用摘要。' 170 665 450 24 -Muted | Out-Null
     $save=Add-UiButton $form '保存配置' 488 704 132 34 'Primary'; $cancel=Add-UiButton $form '取消' 380 704 96 34; $cancel.DialogResult='Cancel'; $form.CancelButton=$cancel
    $save.Add_Click({
        $codex=Resolve-ConfiguredPath $codexBox.Text
        if([string]::IsNullOrWhiteSpace($codex) -or -not [IO.File]::Exists($codex)){Show-Message 'Codex 路径不存在。' '全局配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
        $vscode=Resolve-ConfiguredPath $vscodeBox.Text
        if(-not [string]::IsNullOrWhiteSpace($vscode) -and -not [IO.File]::Exists($vscode)){Show-Message 'VS Code 路径不存在，可留空。' '全局配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
        $pythonInterpreter=Resolve-ConfiguredPath $pythonInterpreterBox.Text
        if(-not [string]::IsNullOrWhiteSpace($pythonInterpreter)-and-not [IO.File]::Exists($pythonInterpreter)){Show-Message 'Python 解释器路径不存在，可留空。' '全局配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
        $previousAiSessionId=[string]$script:GlobalSettings.WorkflowAiSessionId
         $documentEditor=Resolve-ConfiguredPath $documentEditorBox.Text
         if(-not[string]::IsNullOrWhiteSpace($documentEditor)-and-not[IO.File]::Exists($documentEditor)){Show-Message '代码/文档打开器路径不存在，可留空。' '全局配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
         $webPort=[int]$webPortBox.Value
         if($webEnabledCheck.Checked-and[string]::IsNullOrWhiteSpace($webAccessCodeBox.Text)){Show-Message '启用 Web 时必须配置访问码。' '全局配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
         if($webEnabledCheck.Checked-and$webAccessCodeBox.Text.Trim().Length-lt8){Show-Message 'Web 访问码建议至少 8 位。' '全局配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
         $previousWebEnabled=[bool](Get-UiConfigValue $script:GlobalSettings 'WebEnabled' $false);$previousWebPort=[int](Get-UiConfigValue $script:GlobalSettings 'WebPort' 5170);$previousWebCode=[string](Get-UiConfigValue $script:GlobalSettings 'WebAccessCode' '')
        $script:GlobalSettings.CodexPath=$codexBox.Text.Trim(); $script:GlobalSettings.VSCodePath=$vscodeBox.Text.Trim(); $script:GlobalSettings.PythonInterpreterPath=$pythonInterpreterBox.Text.Trim(); $script:GlobalSettings.WorkflowAiSessionId=$workflowAiSessionBox.Text.Trim(); $script:GlobalSettings.DocumentEditorPath=$documentEditorBox.Text.Trim()
         $script:GlobalSettings.ConversationSurfaceColor=[string]$surfaceColorButton.Tag;$script:GlobalSettings.ConversationUserBubbleColor=[string]$userBubbleColorButton.Tag;$script:GlobalSettings.ConversationAssistantBubbleColor=[string]$assistantBubbleColorButton.Tag;$script:GlobalSettings.ConversationInputBackgroundColor=[string]$inputBackgroundColorButton.Tag;$script:GlobalSettings.ConversationInputTextColor=[string]$inputTextColorButton.Tag
         $script:GlobalSettings.WebEnabled=[bool]$webEnabledCheck.Checked;$script:GlobalSettings.WebAccessCode=$webAccessCodeBox.Text.Trim();$script:GlobalSettings.WebPort=$webPort
         if(-not[string]::IsNullOrWhiteSpace($previousAiSessionId)-and[string]::IsNullOrWhiteSpace([string]$script:GlobalSettings.WorkflowAiSessionId)){$script:WorkflowAiConversationHistory=''}
          if($previousWebCode-ne[string]$script:GlobalSettings.WebAccessCode){Stop-WebApiServer};Save-GlobalSettings;Apply-CodexConversationPalette;Sync-WebApiServer;$form.DialogResult='OK'; $form.Close()
    })
    $browseCodex.Add_Click({
        $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Title='选择 Codex 可执行文件'; $dialog.Filter='可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
        $current=Resolve-ConfiguredPath $codexBox.Text; if([IO.File]::Exists($current)){$dialog.FileName=$current}
        if($dialog.ShowDialog($form) -eq 'OK'){$codexBox.Text=$dialog.FileName}; $dialog.Dispose()
    })
    $browseVSCode.Add_Click({
        $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Title='选择 VS Code 可执行文件'; $dialog.Filter='程序文件 (*.exe;*.cmd)|*.exe;*.cmd|所有文件 (*.*)|*.*'
        $current=Resolve-ConfiguredPath $vscodeBox.Text; if([IO.File]::Exists($current)){$dialog.FileName=$current}
        if($dialog.ShowDialog($form) -eq 'OK'){$vscodeBox.Text=$dialog.FileName}; $dialog.Dispose()
    })
    $browseDocumentEditor.Add_Click({
        $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Title='选择代码或文档打开程序'; $dialog.Filter='程序文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
        $current=Resolve-ConfiguredPath $documentEditorBox.Text; if([IO.File]::Exists($current)){$dialog.FileName=$current}
        if($dialog.ShowDialog($form) -eq 'OK'){$documentEditorBox.Text=$dialog.FileName}; $dialog.Dispose()
    })
    $browsePython.Add_Click({
        $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Title='选择 Python 虚拟环境解释器'; $dialog.Filter='Python (*.exe)|*.exe|所有文件 (*.*)|*.*'
        $current=Resolve-ConfiguredPath $pythonInterpreterBox.Text; if([IO.File]::Exists($current)){$dialog.FileName=$current}
        if($dialog.ShowDialog($form) -eq 'OK'){$pythonInterpreterBox.Text=$dialog.FileName}; $dialog.Dispose()
    })
    $resetWorkflowAi.Add_Click({
        $workflowAiSessionBox.Text=''
    })
    $surfaceColorButton.Add_Click({Show-UiColorPicker $surfaceColorButton $form ([Drawing.Color]::FromArgb(248,250,252))})
    $userBubbleColorButton.Add_Click({Show-UiColorPicker $userBubbleColorButton $form ([Drawing.Color]::FromArgb(219,234,254))})
    $assistantBubbleColorButton.Add_Click({Show-UiColorPicker $assistantBubbleColorButton $form ([Drawing.Color]::White)})
    $inputBackgroundColorButton.Add_Click({Show-UiColorPicker $inputBackgroundColorButton $form ([Drawing.Color]::White)})
    $inputTextColorButton.Add_Click({Show-UiColorPicker $inputTextColorButton $form ([Drawing.Color]::FromArgb(15,23,42))})
     $resetColors.Add_Click({
        Set-UiColorPickerButton $surfaceColorButton '#F8FAFC' ([Drawing.Color]::FromArgb(248,250,252))
        Set-UiColorPickerButton $userBubbleColorButton '#DBEAFE' ([Drawing.Color]::FromArgb(219,234,254))
        Set-UiColorPickerButton $assistantBubbleColorButton '#FFFFFF' ([Drawing.Color]::White)
        Set-UiColorPickerButton $inputBackgroundColorButton '#FFFFFF' ([Drawing.Color]::White)
         Set-UiColorPickerButton $inputTextColorButton '#0F172A' ([Drawing.Color]::FromArgb(15,23,42))
     })
     $memoryDiagnostics.Add_Click({ Show-WorkflowMemoryDiagnostics })
     Apply-UiTheme $form
     try{[void]$form.ShowDialog($script:MainForm)}finally{if($null-ne$form-and-not$form.IsDisposed){$form.Dispose()}}
}

function Ensure-DataDirectories {
    foreach ($path in @($script:DataDirectory, $script:LogDirectory,$script:WorkflowAiDirectory,(Get-CodexConversationAttachmentDirectory))) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
}

function New-DefaultGlobalSettings {
    $vscodePath = ''
    foreach ($candidate in @('C:\Users\Admin\AppData\Local\Programs\Microsoft VS Code\Code.exe','C:\Program Files\Microsoft VS Code\Code.exe','D:\tools\vscode\Microsoft VS Code\Code.exe')) {
        if (Test-Path -LiteralPath $candidate) { $vscodePath = $candidate; break }
    }
    if ([string]::IsNullOrWhiteSpace($vscodePath)) { try { $vscodePath = (Get-Command code -ErrorAction Stop).Source } catch { } }
    return [pscustomobject]@{
        CodexPath = 'C:\Users\Admin\.codex\.sandbox-bin\codex.exe'
        VSCodePath = $vscodePath
        PythonInterpreterPath = ''
        WorkflowAiSessionId = ''
        DocumentEditorPath = ''
        ConversationSurfaceColor = '#F8FAFC'
        ConversationUserBubbleColor = '#DBEAFE'
        ConversationAssistantBubbleColor = '#FFFFFF'
        ConversationInputBackgroundColor = '#FFFFFF'
        ConversationInputTextColor = '#0F172A'
        WebEnabled = $false
        WebAccessCode = ''
        WebPort = 5170
        CommonPrompts = @()
    }
}

function Normalize-GlobalSettings {
    param($Settings)
    $defaults = New-DefaultGlobalSettings
    if ($null -eq $Settings) { return $defaults }
    foreach ($name in @('CodexPath','VSCodePath','PythonInterpreterPath','WorkflowAiSessionId','DocumentEditorPath','ConversationSurfaceColor','ConversationUserBubbleColor','ConversationAssistantBubbleColor','ConversationInputBackgroundColor','ConversationInputTextColor')) {
        if ($null -eq $Settings.PSObject.Properties[$name]) { $Settings | Add-Member NoteProperty $name ([string]$defaults.$name) }
    }
    if ($null -eq $Settings.PSObject.Properties['WebEnabled']) { $Settings | Add-Member NoteProperty WebEnabled ([bool]$defaults.WebEnabled) }
    if ($null -eq $Settings.PSObject.Properties['WebAccessCode']) { $Settings | Add-Member NoteProperty WebAccessCode ([string]$defaults.WebAccessCode) }
    if ($null -eq $Settings.PSObject.Properties['WebPort']) { $Settings | Add-Member NoteProperty WebPort ([int]$defaults.WebPort) }
    $webPort = 0
    if (-not [int]::TryParse([string]$Settings.WebPort, [ref]$webPort) -or $webPort -lt 1024 -or $webPort -gt 65535) { $Settings.WebPort = [int]$defaults.WebPort } else { $Settings.WebPort = $webPort }
    $Settings.WebEnabled = [bool]$Settings.WebEnabled
    $Settings.WebAccessCode = [string]$Settings.WebAccessCode
    foreach($colorName in @('ConversationSurfaceColor','ConversationUserBubbleColor','ConversationAssistantBubbleColor','ConversationInputBackgroundColor','ConversationInputTextColor')){
        $fallbackColor=ConvertTo-UiColor ([string]$defaults.$colorName) ([Drawing.Color]::White)
        $Settings.$colorName=ConvertTo-UiColorHex (ConvertTo-UiColor ([string]$Settings.$colorName) $fallbackColor)
    }
    if ($null -eq $Settings.PSObject.Properties['CommonPrompts']) { $Settings | Add-Member NoteProperty CommonPrompts @() }
    $Settings.CommonPrompts = @(
        $Settings.CommonPrompts |
        Where-Object { $_ -isnot [bool] } |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'False' }
    )
    return $Settings
}

function Normalize-ProjectCodexSession {
    param($Session, [string]$DefaultDescription = '无描述')
    if ($null -eq $Session) { return $null }
    if ($Session -is [string]) {
        $sessionId = ([string]$Session).Trim()
        if ([string]::IsNullOrWhiteSpace($sessionId)) { return $null }
        return [pscustomobject]@{ SessionId=$sessionId; CodexModel=''; Description=$DefaultDescription }
    }
    $recognized=$false
    foreach($field in @('SessionId','session_id','CodexSessionId','CodexModel','Model','Description')){if(Test-UiConfigValue $Session $field){$recognized=$true;break}}
    if(-not$recognized){return $null}
    $sessionId=[string](Get-UiConfigValue $Session 'SessionId' (Get-UiConfigValue $Session 'session_id' (Get-UiConfigValue $Session 'CodexSessionId' '')))
    $model=[string](Get-UiConfigValue $Session 'CodexModel' (Get-UiConfigValue $Session 'Model' ''))
    $description=[string](Get-UiConfigValue $Session 'Description' '')
    $sessionId=$sessionId.Trim();$model=$model.Trim();$description=$description.Trim()
    if([string]::IsNullOrWhiteSpace($sessionId)-and[string]::IsNullOrWhiteSpace($model)-and[string]::IsNullOrWhiteSpace($description)){return $null}
    if([string]::IsNullOrWhiteSpace($description)){$description=$DefaultDescription}
    return [pscustomobject]@{SessionId=$sessionId;CodexModel=$model;Description=$description}
}

function Get-ProjectCodexSessions {
    param($Project,[switch]$Normalize)
    if($null-eq$Project){return @()}
    if(-not$Normalize-and(Test-UiConfigValue $Project 'CodexSessions')){
        $storedSessions=@(Get-UiConfigValue $Project 'CodexSessions' @())
        if($storedSessions.Count-gt0){return $storedSessions}
    }
    $result=New-Object System.Collections.ArrayList
    $seen=@{}
    if(Test-UiConfigValue $Project 'CodexSessions'){
        foreach($item in @(Get-UiConfigValue $Project 'CodexSessions' @())){
            $normalized=Normalize-ProjectCodexSession $item
            if($null-eq$normalized){continue}
            $normalizedId=[string]$normalized.SessionId
            if(-not[string]::IsNullOrWhiteSpace($normalizedId)){
                $key=$normalizedId.ToLowerInvariant();if($seen.ContainsKey($key)){continue};$seen[$key]=$true
            }
            [void]$result.Add($normalized)
        }
    }else{
        $legacyId=[string](Get-UiConfigValue $Project 'CodexSessionId' '')
        if(-not[string]::IsNullOrWhiteSpace($legacyId)){
            [void]$result.Add([pscustomobject]@{SessionId=$legacyId.Trim();CodexModel=([string](Get-UiConfigValue $Project 'CodexModel' '')).Trim();Description='默认主会话'})
        }
    }
    if($result.Count-eq0){
        $legacyId=[string](Get-UiConfigValue $Project 'CodexSessionId' '')
        if(-not[string]::IsNullOrWhiteSpace($legacyId)){[void]$result.Add([pscustomobject]@{SessionId=$legacyId.Trim();CodexModel=([string](Get-UiConfigValue $Project 'CodexModel' '')).Trim();Description='默认主会话'})}
    }
    return @($result)
}

function Set-ProjectCodexSessions {
    param($Project,[object[]]$Sessions=@())
    if($null-eq$Project){return}
    $normalized=New-Object System.Collections.ArrayList;$seen=@{}
    foreach($item in @($Sessions)){
        $entry=Normalize-ProjectCodexSession $item
        if($null-eq$entry){continue}
        $entryId=[string]$entry.SessionId
        if(-not[string]::IsNullOrWhiteSpace($entryId)){
            $key=$entryId.ToLowerInvariant();if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        }
        [void]$normalized.Add($entry)
    }
    $sessionArray=@($normalized)
    if($null-eq$Project.PSObject.Properties['CodexSessions']){$Project|Add-Member NoteProperty CodexSessions $sessionArray}else{$Project.CodexSessions=$sessionArray}
    $primary=if($sessionArray.Count-gt0){$sessionArray[0]}else{$null}
    $primaryId=if($null-ne$primary){[string]$primary.SessionId}else{''};$primaryModel=if($null-ne$primary){[string]$primary.CodexModel}else{''}
    if($null-eq$Project.PSObject.Properties['CodexSessionId']){$Project|Add-Member NoteProperty CodexSessionId $primaryId}else{$Project.CodexSessionId=$primaryId}
    if($null-eq$Project.PSObject.Properties['CodexModel']){$Project|Add-Member NoteProperty CodexModel $primaryModel}else{$Project.CodexModel=$primaryModel}
}

function Get-ProjectPrimaryCodexSession {
    param($Project)
    $sessions=@(Get-ProjectCodexSessions $Project)
    if($sessions.Count-eq0){return $null}
    return $sessions[0]
}

function Get-ProjectCodexSession {
    param($Project,[string]$SessionId='')
    $sessions=@(Get-ProjectCodexSessions $Project)
    if([string]::IsNullOrWhiteSpace($SessionId)){if($sessions.Count-gt0){return $sessions[0]};return $null}
    foreach($session in $sessions){
        if([string]$session.SessionId-eq$SessionId){return $session}
    }
    return $null
}

function New-Project {
    param([string]$Name = '新项目', [string]$DefaultWorkingDirectory = '', [string]$CodexSessionId = '', [string]$CodexModel = '', [object[]]$CodexSessions = @())
    $project=[pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Name = $Name
        DefaultWorkingDirectory = $DefaultWorkingDirectory
        CodexSessions = @()
        CodexSessionId = ''
        CodexModel = ''
        UpdatedAt = (Get-Date).ToString('o')
    }
    $sessions=@($CodexSessions)
    if($sessions.Count-eq0-and(-not[string]::IsNullOrWhiteSpace($CodexSessionId)-or-not[string]::IsNullOrWhiteSpace($CodexModel))){$sessions=@([pscustomobject]@{SessionId=$CodexSessionId;CodexModel=$CodexModel;Description='默认主会话'})}
    Set-ProjectCodexSessions $project $sessions
    return $project
}

function Normalize-Project {
    param($Project)
    if ($null -eq $Project -or $Project -is [string] -or $Project.GetType().IsPrimitive) { return $null }
    $recognized = $false
    foreach ($fieldName in @('Id','Name','DefaultWorkingDirectory','CodexSessions','CodexSessionId','CodexModel','UpdatedAt')) {
        if (Test-UiConfigValue $Project $fieldName) { $recognized = $true; break }
    }
    if (-not $recognized) { return $null }
    $id = [string](Get-UiConfigValue $Project 'Id' '')
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [guid]::NewGuid().ToString() }
    $name = [string](Get-UiConfigValue $Project 'Name' '未命名项目')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = '未命名项目' }
    $updatedAt = if (Test-UiConfigValue $Project 'UpdatedAt') { [string](Get-UiConfigValue $Project 'UpdatedAt' '') } else { (Get-Date).ToString('o') }
    $normalized=[pscustomobject]@{
        Id = $id
        Name = $name
        DefaultWorkingDirectory = [string](Get-UiConfigValue $Project 'DefaultWorkingDirectory' '')
        CodexSessions = @()
        CodexSessionId = ''
        CodexModel = ''
        UpdatedAt = $updatedAt
    }
    $sourceSessions=@(Get-ProjectCodexSessions $Project -Normalize)
    Set-ProjectCodexSessions $normalized $sourceSessions
    if($sourceSessions.Count-eq0){$legacyModel=[string](Get-UiConfigValue $Project 'CodexModel' '');if(-not[string]::IsNullOrWhiteSpace($legacyModel)){$normalized.CodexModel=$legacyModel.Trim()}}
    return $normalized
}

function Write-JsonFileAtomic {
    param([string]$Path, $Value, [int]$Depth = 30)
    $json = $Value | ConvertTo-Json -Depth $Depth
    $temp = $Path + '.tmp'
    [IO.File]::WriteAllText($temp, $json, [Text.Encoding]::UTF8)
    if (Test-Path -LiteralPath $Path) {
        $backup = $Path + '.bak'
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        [IO.File]::Replace($temp, $Path, $backup)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    } else {
        Move-Item -LiteralPath $temp -Destination $Path
    }
}

function Load-Projects {
    Ensure-DataDirectories
    if (-not (Test-Path -LiteralPath $script:ProjectPath)) { return @() }
    try {
        $data = [IO.File]::ReadAllText($script:ProjectPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $pending = New-Object 'System.Collections.Generic.Queue[object]'
        $projects = New-Object System.Collections.ArrayList
        $pending.Enqueue($data)
        while ($pending.Count -gt 0) {
            $item = $pending.Dequeue()
            if ($null -eq $item) { continue }
            if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string] -and $item -isnot [System.Collections.IDictionary] -and $item -isnot [pscustomobject]) {
                foreach ($child in $item) { $pending.Enqueue($child) }
                continue
            }
            if (Test-UiConfigValue $item 'Projects') {
                $wrappedProjects = Get-UiConfigValue $item 'Projects' $null
                if ($null -ne $wrappedProjects) { $pending.Enqueue($wrappedProjects) }
                continue
            }
            $normalized = Normalize-Project $item
            if ($null -ne $normalized) { [void]$projects.Add($normalized) }
        }
        return @($projects)
    } catch {
        Show-Message "读取项目失败：$($_.Exception.Message)" '加载失败' ([Windows.Forms.MessageBoxIcon]::Error)
        return @()
    }
}

function Save-Projects {
    Ensure-DataDirectories
    Write-JsonFileAtomic $script:ProjectPath @($script:Projects)
}

function Load-GlobalSettings {
    Ensure-DataDirectories
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return (New-DefaultGlobalSettings) }
    try { return (Normalize-GlobalSettings ([IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)) }
    catch {
        Show-Message "读取全局配置失败：$($_.Exception.Message)" '加载失败' ([Windows.Forms.MessageBoxIcon]::Error)
        return (New-DefaultGlobalSettings)
    }
}

function Save-GlobalSettings {
    Ensure-DataDirectories
    Write-JsonFileAtomic $script:SettingsPath $script:GlobalSettings
}

function Get-ProjectById {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    foreach($project in @($script:Projects)){
        if([string]$project.Id-eq$Id){return $project}
    }
    return $null
}

function Get-WorkflowProject {
    param($Workflow)
    if ($null -eq $Workflow) { return $null }
    return (Get-ProjectById ([string](Get-UiConfigValue $Workflow 'ProjectId' '')))
}

function Get-CurrentProjectId {
    if ($null -eq $script:CurrentProject) { return '' }
    return [string]$script:CurrentProject.Id
}

function ConvertTo-ApiJson {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 40 -Compress)
}

function New-ApiSuccess {
    param($Data, [int]$StatusCode = 200)
    return [pscustomobject]@{ StatusCode = $StatusCode; Body = (ConvertTo-ApiJson ([pscustomobject]@{ ok = $true; data = $Data })) }
}

function New-ApiError {
    param([int]$StatusCode, [string]$Code, [string]$Message, $Details = $null)
    $errorValue = [ordered]@{ code = $Code; message = $Message }
    if ($null -ne $Details) { $errorValue.details = $Details }
    return [pscustomobject]@{ StatusCode = $StatusCode; Body = (ConvertTo-ApiJson ([pscustomobject]@{ ok = $false; error = [pscustomobject]$errorValue })) }
}

function ConvertFrom-ApiJsonBody {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return [pscustomobject]@{} }
    try { return ($Body | ConvertFrom-Json) }
    catch { throw '请求体必须是有效的 UTF-8 JSON。' }
}

function Get-ApiQueryMap {
    param([string]$Query)
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Query)) { return $result }
    foreach ($part in $Query.TrimStart('?').Split('&')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $pair = $part.Split('=', 2)
        $name = [Uri]::UnescapeDataString($pair[0].Replace('+',' '))
        $value = if ($pair.Count -gt 1) { [Uri]::UnescapeDataString($pair[1].Replace('+',' ')) } else { '' }
        $result[$name] = $value
    }
    return $result
}

function Remove-ExpiredWebApiSessions {
    $now = Get-Date
    foreach ($token in @($script:WebApiSessions.Keys)) {
        $session = $script:WebApiSessions[$token]
        if ($null -eq $session -or (($now - [datetime]$session.LastUsedAt).TotalMinutes -gt $script:WebApiSessionTimeoutMinutes)) { [void]$script:WebApiSessions.Remove($token) }
    }
}

function Get-WebRequestToken {
    param([hashtable]$Headers = @{})
    $authorization = if ($Headers.ContainsKey('Authorization')) { [string]$Headers['Authorization'] } else { '' }
    if ($authorization -match '^Bearer\s+(.+)$') { return $Matches[1].Trim() }
    if ($Headers.ContainsKey('Cookie')) {
        foreach ($part in ([string]$Headers['Cookie']).Split(';')) { $pair = $part.Trim().Split('=',2); if ($pair.Count -eq 2 -and $pair[0] -eq 'shijia_web_token') { return [Uri]::UnescapeDataString($pair[1]) } }
    }
    return ''
}

function Test-WebAccessCode {
    param([string]$ConfiguredCode, [string]$SubmittedCode)
    if ([string]::IsNullOrEmpty($ConfiguredCode) -or $null -eq $SubmittedCode) { return $false }
    $left = [Text.Encoding]::UTF8.GetBytes($ConfiguredCode); $right = [Text.Encoding]::UTF8.GetBytes($SubmittedCode)
    if ($left.Length -ne $right.Length) { return $false }
    $different = 0
    for ($i=0; $i -lt $left.Length; $i++) { $different = $different -bor ($left[$i] -bxor $right[$i]) }
    return ($different -eq 0)
}

function Get-WebAuthenticatedSession {
    param([hashtable]$Headers = @{})
    Remove-ExpiredWebApiSessions
    $token = Get-WebRequestToken $Headers
    if ([string]::IsNullOrWhiteSpace($token) -or -not $script:WebApiSessions.ContainsKey($token)) { return $null }
    $session = $script:WebApiSessions[$token]; $session.LastUsedAt = Get-Date; return $session
}

function Get-WebProjectSessionItems {
    param($Project)
    if ($null -eq $Project) { return @() }
    $result = New-Object System.Collections.ArrayList; $index = 0
    foreach ($session in @(Get-ProjectCodexSessions $Project)) {
        $sessionId = [string]$session.SessionId
        $key = Get-CodexConversationProcessKey 'Project' ([string]$Project.Id) $sessionId $index
        $status = if (Test-CodexConversationProcessRunning $key) { '对话进行中' } elseif (Test-CodexConversationProcessBusy $key) { '回复同步中' } elseif ($null -ne (Get-ProjectCodexSessionBusyRecord $Project $sessionId)) { '工作流调用中' } elseif ([string]::IsNullOrWhiteSpace($sessionId)) { '未创建' } else { '已完成' }
        $record = if ([string]::IsNullOrWhiteSpace($sessionId)) { $null } else { Get-CodexSessionRecord $sessionId }
        $lastWrite = if ($null -ne $record) { [string](Get-UiConfigValue $record 'last_write_time' '') } else { '' }
        $sessionKey=if([string]::IsNullOrWhiteSpace($sessionId)){('_new-'+[string]$index)}else{$sessionId}
        [void]$result.Add([pscustomobject]@{ projectId=[string]$Project.Id; projectName=[string]$Project.Name; sessionId=$sessionId; sessionKey=$sessionKey; description=[string]$session.Description; model=[string]$session.CodexModel; status=$status; updatedAt=$lastWrite; index=$index })
        $index++
    }
    return @($result)
}

function Get-WebProjectSummaryItems {
    $items = New-Object System.Collections.ArrayList
    foreach ($project in @(Get-ApiProjectItems)) {
        $projectId = [string]$project.id
        $realProject = if ([string]::IsNullOrWhiteSpace($projectId)) { $null } else { Get-ProjectById $projectId }
        $sessions = if ($null -ne $realProject) { @(Get-WebProjectSessionItems $realProject) } else { @() }
        $workflows = @($project.workflows | ForEach-Object { $workflowId=[string]$_.id; [pscustomobject]@{ id=$workflowId; name=[string]$_.name; enabled=[bool]$_.enabled; running=((-not [string]::IsNullOrWhiteSpace($workflowId)) -and $script:RunningJobs.ContainsKey($workflowId)); updatedAt=[string]$_.updatedAt } })
        [void]$items.Add([pscustomobject]@{ id=$projectId; name=[string]$project.name; defaultWorkingDirectory=[string]$project.defaultWorkingDirectory; updatedAt=[string]$project.updatedAt; workflowCount=$workflows.Count; codexSessions=$sessions; workflows=$workflows })
    }
    return @($items)
}

function Get-WebProjectSessionRoute {
    param($Project, [string]$SessionKey = '')
    if ($null -eq $Project) { return $null }
    $sessions = @(Get-ProjectCodexSessions $Project)
    $routeKey = [Uri]::UnescapeDataString([string]$SessionKey)
    if ([string]::IsNullOrWhiteSpace($routeKey)) { $routeKey = '_new-0' }
    $index = -1
    $session = $null
    if ($routeKey -match '^_new-(\d+)$') {
        $index = [int]$Matches[1]
        if ($index -ge 0 -and $index -lt $sessions.Count -and [string]::IsNullOrWhiteSpace([string]$sessions[$index].SessionId)) { $session = $sessions[$index] }
    } elseif ($routeKey -eq '_new') {
        for ($candidateIndex = 0; $candidateIndex -lt $sessions.Count; $candidateIndex++) {
            if ([string]::IsNullOrWhiteSpace([string]$sessions[$candidateIndex].SessionId)) { $index = $candidateIndex; $session = $sessions[$candidateIndex]; break }
        }
    } else {
        for ($candidateIndex = 0; $candidateIndex -lt $sessions.Count; $candidateIndex++) {
            if ([string]$sessions[$candidateIndex].SessionId -eq $routeKey) { $index = $candidateIndex; $session = $sessions[$candidateIndex]; break }
        }
    }
    if ($null -eq $session) { return $null }
    $actualSessionId = [string]$session.SessionId
    return [pscustomobject]@{
        Session = $session
        Index = $index
        SessionId = $actualSessionId
        SessionKey = if ([string]::IsNullOrWhiteSpace($actualSessionId)) { '_new-' + $index } else { $actualSessionId }
        ProcessKey = Get-CodexConversationProcessKey 'Project' ([string]$Project.Id) $actualSessionId $index
    }
}

function Get-WebRunningTaskItems {
    $result = New-Object System.Collections.ArrayList
    foreach ($workflowId in @($script:RunningJobs.Keys | Sort-Object)) {
        $record = $script:RunningJobs[$workflowId]
        if ($null -eq $record) { continue }
        $logs = New-Object System.Collections.Generic.List[object]
        foreach($log in @(Get-CodexConversationTail (Get-UiConfigValue $record 'Logs' @()) 200)){
            $logs.Add([pscustomobject]@{at=[string](Get-UiConfigValue $log 'At' '');level=[string](Get-UiConfigValue $log 'Level' 'INFO');kind=[string](Get-UiConfigValue $log 'Kind' '');message=[string](Get-UiConfigValue $log 'Message' $log)})
        }
        [void]$result.Add([pscustomobject]@{ workflowId=[string]$record.WorkflowId; workflowName=[string]$record.WorkflowName; status=[string]$record.Status; currentNodeId=[string]$record.CurrentNodeId; currentNodeName=[string]$record.CurrentNodeName; currentNodeType=[string]$record.CurrentNodeType; startedAt=([datetime]$record.StartedAt).ToString('o'); activeProcessId=[int](Get-UiConfigValue $record 'ActiveProcessId' 0); activeCodexSessionId=[string](Get-UiConfigValue $record 'ActiveCodexSessionId' ''); logs=$logs.ToArray() })
    }
    return @($result)
}

function Get-WebSessionDetail {
    param($Project, [string]$SessionId)
    $route = Get-WebProjectSessionRoute $Project $SessionId
    if ($null -eq $route) { return $null }
    $session = $route.Session
    $summary=$null
    foreach($candidate in @(Get-WebProjectSessionItems $Project)){if([string]$candidate.sessionKey-eq[string]$route.SessionKey){$summary=$candidate;break}}
    $messages = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$route.SessionId)) {
        try {
            $conversation=Get-CodexSessionConversation ([string]$route.SessionId) 80
            $messageItems=New-Object System.Collections.Generic.List[object]
            foreach($message in @($conversation.Messages)){$messageItems.Add([pscustomobject]@{role=[string]$message.Role;text=[string]$message.Text;timestamp=[string](Get-UiConfigValue $message 'Timestamp' (Get-UiConfigValue $message 'Time' ''))})}
            $messages=$messageItems.ToArray()
        } catch { }
    }
    $processKey=[string]$route.ProcessKey
    $record=if($script:CodexConversationProcesses.ContainsKey($processKey)){$script:CodexConversationProcesses[$processKey]}else{$null}
    if($null-ne$record -and -not[string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $record 'PendingPrompt' ''))){
        $pending=[string](Get-UiConfigValue $record 'PendingPrompt' '')
        $already=@($messages|Where-Object{[string]$_.role-eq'user'-and[string]$_.text-eq$pending}).Count-gt0
        if(-not$already){$messages=@($messages)+@([pscustomobject]@{role='user';text=$pending;timestamp=([datetime](Get-UiConfigValue $record 'StartedAt' (Get-Date))).ToString('o');pending=$true})}
    }
    $status=if($null-ne$summary){[string]$summary.status}else{'未创建'}
    return [pscustomobject]@{ projectId=[string]$Project.Id; projectName=[string]$Project.Name; sessionId=[string]$route.SessionId; sessionKey=[string]$route.SessionKey; index=[int]$route.Index; description=[string]$session.Description; model=[string]$session.CodexModel; status=$status; running=(Test-CodexConversationProcessRunning $processKey); busy=(Test-CodexConversationProcessBusy $processKey); messages=$messages }
}

function Get-WebPageHtml {
    $path = Join-Path $script:ApplicationDirectory 'web\index.html'
    if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
    return '<!doctype html><meta charset=utf-8><title>使驾 Web</title><h1>Web 页面文件未找到</h1><p>请重新构建使驾，确保 web\index.html 已复制到程序目录。</p>'
}

function Stop-ProjectCodexConversationRequest {
    param($Project, [string]$SessionKey = '')
    $route=Get-WebProjectSessionRoute $Project $SessionKey
    if($null-eq$route){return [pscustomobject]@{Stopped=$false;Error='会话不存在。';Code='session_not_found'}}
    $processKey=[string]$route.ProcessKey
    if(-not$script:CodexConversationProcesses.ContainsKey($processKey)){return [pscustomobject]@{Stopped=$false;Error='会话当前没有运行。';Code='conversation_not_running';ProcessKey=$processKey}}
    $record=$script:CodexConversationProcesses[$processKey]
    if($null-eq$record){return [pscustomobject]@{Stopped=$false;Error='会话当前没有运行。';Code='conversation_not_running';ProcessKey=$processKey}}
    try{
        Set-CodexConversationRecordValue $record 'StopRequested' $true
        Set-CodexConversationRecordValue $record 'TerminationReason' 'ManualStop'
        Stop-WorkflowProcessTree ([int]$record.Process.Id)
        return [pscustomobject]@{Stopped=$true;ProcessKey=$processKey;SessionKey=[string]$route.SessionKey}
    }catch{
        return [pscustomobject]@{Stopped=$false;Error=('停止会话失败：'+$_.Exception.Message);Code='conversation_stop_failed';ProcessKey=$processKey}
    }
}

function Invoke-WorkflowWebOperation {
    param([string]$Method, [string]$Target, [string]$Body = '', [hashtable]$Headers = @{})
    $Method = $Method.ToUpperInvariant()
    $uri = [Uri]('http://127.0.0.1' + $Target)
    $path = $uri.AbsolutePath.TrimEnd('/'); if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }
    try {
        if ($path -in @('/web','/web/index.html') -and $Method -eq 'GET') { return [pscustomobject]@{StatusCode=200;ResponseContentType='text/html; charset=utf-8';Body=(Get-WebPageHtml)} }
        if ($path -eq '/web/api/auth/login' -and $Method -eq 'POST') {
            $configured = [string](Get-UiConfigValue $script:GlobalSettings 'WebAccessCode' '')
            if ([string]::IsNullOrWhiteSpace($configured)) { return (New-ApiError 503 'web_not_configured' 'Web 访问码尚未配置。') }
            $payload = ConvertFrom-ApiJsonBody $Body; $submitted = [string](Get-UiConfigValue $payload 'accessCode' '')
            if (-not (Test-WebAccessCode $configured $submitted)) { return (New-ApiError 401 'invalid_access_code' '访问码错误。') }
            $token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
            $script:WebApiSessions[$token] = [pscustomobject]@{CreatedAt=Get-Date;LastUsedAt=Get-Date}
            return (New-ApiSuccess ([pscustomobject]@{token=$token;expiresIn=([int]($script:WebApiSessionTimeoutMinutes*60))}))
        }
        if ($path -eq '/web/api/auth/me' -and $Method -eq 'GET') {
            $session = Get-WebAuthenticatedSession $Headers
            if ($null -eq $session) { return (New-ApiError 401 'unauthorized' '需要有效的 Web 登录令牌。') }
            return (New-ApiSuccess ([pscustomobject]@{authenticated=$true}))
        }
        if ($path -eq '/web/api/auth/logout' -and $Method -eq 'POST') {
            if ($null -eq (Get-WebAuthenticatedSession $Headers)) { return (New-ApiError 401 'unauthorized' '需要有效的 Web 登录令牌。') }
            $token = Get-WebRequestToken $Headers
            if (-not [string]::IsNullOrWhiteSpace($token)) { [void]$script:WebApiSessions.Remove($token) }
            return (New-ApiSuccess ([pscustomobject]@{loggedOut=$true}))
        }
        if ($null -eq (Get-WebAuthenticatedSession $Headers)) { return (New-ApiError 401 'unauthorized' '需要有效的 Web 登录令牌。') }
        Complete-ProjectCodexMessage
        if ($path -eq '/web/api/bootstrap' -and $Method -eq 'GET') {
            $projects = @(Get-WebProjectSummaryItems); $selected = if ($null -ne $script:CurrentProject) {[string]$script:CurrentProject.Id} elseif ($projects.Count -gt 0) {[string]$projects[0].id} else {''}
            return (New-ApiSuccess ([pscustomobject]@{projects=$projects;selectedProject=$selected;running=@(Get-WebRunningTaskItems);server=[pscustomobject]@{name='使驾';port=[int](Get-UiConfigValue $script:GlobalSettings 'WebPort' $script:WebApiPort)}}))
        }
        if ($path -eq '/web/api/projects' -and $Method -eq 'GET') { $projects=@(Get-WebProjectSummaryItems); return (New-ApiSuccess ([pscustomobject]@{projects=$projects;count=$projects.Count})) }
        if ($path -eq '/web/api/sessions' -and $Method -eq 'GET') {
            $sessions=New-Object System.Collections.ArrayList; foreach($project in @($script:Projects)){foreach($item in @(Get-WebProjectSessionItems $project)){[void]$sessions.Add($item)}}
            return (New-ApiSuccess ([pscustomobject]@{sessions=@($sessions);count=$sessions.Count}))
        }
        if ($path -match '^/web/api/projects/([^/]+)$' -and $Method -eq 'GET') {
            $project=Get-ProjectById ([Uri]::UnescapeDataString($Matches[1])); if($null -eq $project){return(New-ApiError 404 'project_not_found' '项目不存在。')}
            $summary=@(Get-WebProjectSummaryItems|Where-Object{[string]$_.id-eq[string]$project.Id}|Select-Object -First 1);if($summary.Count-eq0){return(New-ApiError 404 'project_not_found' '项目不存在。')};return(New-ApiSuccess $summary[0])
        }
        if ($path -match '^/web/api/projects/([^/]+)/sessions$' -and $Method -eq 'GET') {
            $project=Get-ProjectById ([Uri]::UnescapeDataString($Matches[1]));if($null -eq $project){return(New-ApiError 404 'project_not_found' '项目不存在。')};return(New-ApiSuccess ([pscustomobject]@{sessions=@(Get-WebProjectSessionItems $project)}))
        }
        if ($path -match '^/web/api/projects/([^/]+)/sessions$' -and $Method -eq 'POST') {
            $projectId=[Uri]::UnescapeDataString($Matches[1]);$project=Get-ProjectById $projectId;if($null-eq$project){return(New-ApiError 404 'project_not_found' '项目不存在。')}
            $payload=ConvertFrom-ApiJsonBody $Body;$description=[string](Get-UiConfigValue $payload 'description' '无描述');$model=[string](Get-UiConfigValue $payload 'model' (Get-UiConfigValue $payload 'codexModel' ''))
            if([string]::IsNullOrWhiteSpace($description)){$description='无描述'}
            $sessions=@(Get-ProjectCodexSessions $project);$entry=[pscustomobject]@{SessionId='';CodexModel=$model.Trim();Description=$description.Trim()};$sessions=@($sessions)+@($entry);Set-ProjectCodexSessions $project $sessions;$project.UpdatedAt=(Get-Date).ToString('o');Save-Projects
            $index=$sessions.Count-1;$item=Get-WebProjectSessionItems $project|Where-Object{[int]$_.index-eq$index}|Select-Object -First 1
            return(New-ApiSuccess $item 201)
        }
        if ($path -match '^/web/api/projects/([^/]+)/sessions/([^/]+)$' -and $Method -eq 'GET') {
            $project=Get-ProjectById ([Uri]::UnescapeDataString($Matches[1]));$sessionKey=[Uri]::UnescapeDataString($Matches[2]);if($null -eq $project){return(New-ApiError 404 'project_not_found' '项目不存在。')};$detail=Get-WebSessionDetail $project $sessionKey;if($null -eq $detail){return(New-ApiError 404 'session_not_found' '会话不存在。')};return(New-ApiSuccess $detail)
        }
        if ($path -match '^/web/api/projects/([^/]+)/sessions/([^/]+)/status$' -and $Method -eq 'GET') {
            $project=Get-ProjectById ([Uri]::UnescapeDataString($Matches[1]));$sessionKey=[Uri]::UnescapeDataString($Matches[2]);if($null-eq$project){return(New-ApiError 404 'project_not_found' '项目不存在。')};$detail=Get-WebSessionDetail $project $sessionKey;if($null-eq$detail){return(New-ApiError 404 'session_not_found' '会话不存在。')};return(New-ApiSuccess ([pscustomobject]@{projectId=$detail.projectId;sessionKey=$detail.sessionKey;sessionId=$detail.sessionId;description=$detail.description;model=$detail.model;status=$detail.status;running=$detail.running;busy=$detail.busy;updatedAt=(Get-Date).ToString('o')}))
        }
        if ($path -match '^/web/api/projects/([^/]+)/sessions/([^/]+)/messages$' -and $Method -eq 'GET') {
            $project=Get-ProjectById ([Uri]::UnescapeDataString($Matches[1]));$sessionKey=[Uri]::UnescapeDataString($Matches[2]);if($null-eq$project){return(New-ApiError 404 'project_not_found' '项目不存在。')};$detail=Get-WebSessionDetail $project $sessionKey;if($null-eq$detail){return(New-ApiError 404 'session_not_found' '会话不存在。')};return(New-ApiSuccess ([pscustomobject]@{projectId=$detail.projectId;sessionKey=$detail.sessionKey;sessionId=$detail.sessionId;description=$detail.description;model=$detail.model;status=$detail.status;running=$detail.running;busy=$detail.busy;messages=$detail.messages}))
        }
        if ($path -match '^/web/api/projects/([^/]+)/sessions/([^/]+)/messages$' -and $Method -eq 'POST') {
            $project=Get-ProjectById ([Uri]::UnescapeDataString($Matches[1]));$sessionKey=[Uri]::UnescapeDataString($Matches[2]);if($null-eq$project){return(New-ApiError 404 'project_not_found' '项目不存在。')};$route=Get-WebProjectSessionRoute $project $sessionKey;if($null-eq$route){return(New-ApiError 404 'session_not_found' '会话不存在。')};$payload=ConvertFrom-ApiJsonBody $Body;$prompt=[string](Get-UiConfigValue $payload 'message' (Get-UiConfigValue $payload 'prompt' ''));if([string]::IsNullOrWhiteSpace($prompt)){return(New-ApiError 400 'validation_error' 'message 不能为空。')};$started=Start-ProjectCodexConversationRequest $project $route.Session $route.Index $prompt 'Web' @();if(-not$started.Started){$status=if([string]$started.Code-eq'conversation_busy'){409}else{400};return(New-ApiError $status ([string]$started.Code) ([string]$started.Error))};return(New-ApiSuccess ([pscustomobject]@{started=$true;projectId=$project.Id;sessionKey=$started.SessionKey;sessionId=$started.SessionId;description=$started.Description;model=$started.Model;status='对话进行中';startedAt=([datetime]$started.StartedAt).ToString('o')}) 202)
        }
        if ($path -match '^/web/api/projects/([^/]+)/sessions/([^/]+)/stop$' -and $Method -eq 'POST') {
            $project=Get-ProjectById ([Uri]::UnescapeDataString($Matches[1]));$sessionKey=[Uri]::UnescapeDataString($Matches[2]);if($null-eq$project){return(New-ApiError 404 'project_not_found' '项目不存在。')};$stopped=Stop-ProjectCodexConversationRequest $project $sessionKey;if(-not$stopped.Stopped){return(New-ApiError 409 ([string]$stopped.Code) ([string]$stopped.Error))};return(New-ApiSuccess ([pscustomobject]@{stopped=$true;sessionKey=$stopped.SessionKey}))
        }
        if ($path -match '^/web/api/projects/([^/]*)/workflows$' -and $Method -eq 'GET') {
            $projectId=[Uri]::UnescapeDataString($Matches[1])
            $isUngrouped=$projectId-in@('','_ungrouped','ungrouped')
            if($isUngrouped){$projectId=''}else{$project=Get-ProjectById $projectId;if($null -eq $project){return(New-ApiError 404 'project_not_found' '项目不存在。')}}
            $items=@(Get-WebProjectSummaryItems|Where-Object{[string]$_.id-eq$projectId}|Select-Object -First 1)
            return(New-ApiSuccess ([pscustomobject]@{projectId=$projectId;workflows=if($items.Count-gt0){@($items[0].workflows)}else{@()}}))
        }
        if ($path -match '^/web/api/projects/([^/]*)/workflows/([^/]+)/(run|stop)$' -and $Method -eq 'POST') {
            $projectId=[Uri]::UnescapeDataString($Matches[1]);$workflowId=[Uri]::UnescapeDataString($Matches[2]);$action=$Matches[3]
            $isUngrouped=$projectId-in@('','_ungrouped','ungrouped')
            if($isUngrouped){$projectId=''}else{$project=Get-ProjectById $projectId;if($null -eq $project){return(New-ApiError 404 'project_not_found' '项目不存在。')}}
            $workflow=@($script:Workflows|Where-Object{[string]$_.Id-eq$workflowId-and[string](Get-UiConfigValue $_ 'ProjectId' '')-eq$projectId}|Select-Object -First 1)
            if($workflow.Count-eq0){$scopeName=if($isUngrouped){'无项目'}else{'该项目'};return(New-ApiError 404 'workflow_not_found' ($scopeName+'下不存在此工作流。'))}
            if($action-eq'run'){if($script:RunningJobs.ContainsKey($workflowId)){return(New-ApiError 409 'workflow_running' '工作流已经在运行。')};[void](Start-WorkflowJob $workflow[0] -Manual);return(New-ApiSuccess ([pscustomobject]@{started=$true;workflowId=$workflowId;projectId=$projectId}))}
            [void](Stop-WorkflowJob $workflowId -Silent);return(New-ApiSuccess ([pscustomobject]@{stopped=$true;workflowId=$workflowId;projectId=$projectId}))
        }
        if ($path -match '^/web/api/workflows/([^/]+)/(run|stop)$' -and $Method -eq 'POST') {
            $workflowId=[Uri]::UnescapeDataString($Matches[1]);$action=$Matches[2]
            $workflow=@($script:Workflows|Where-Object{[string]$_.Id-eq$workflowId-and[string](Get-UiConfigValue $_ 'ProjectId' '')-eq''}|Select-Object -First 1)
            if($workflow.Count-eq0){return(New-ApiError 404 'workflow_not_found' '无项目下不存在此工作流。')}
            if($action-eq'run'){if($script:RunningJobs.ContainsKey($workflowId)){return(New-ApiError 409 'workflow_running' '工作流已经在运行。')};[void](Start-WorkflowJob $workflow[0] -Manual);return(New-ApiSuccess ([pscustomobject]@{started=$true;workflowId=$workflowId;projectId=''}))}
            [void](Stop-WorkflowJob $workflowId -Silent);return(New-ApiSuccess ([pscustomobject]@{stopped=$true;workflowId=$workflowId;projectId=''}))
        }
        if ($path -eq '/web/api/running' -and $Method -eq 'GET') { return(New-ApiSuccess ([pscustomobject]@{tasks=@(Get-WebRunningTaskItems);count=$script:RunningJobs.Count})) }
        if ($path -match '^/web/api/running/([^/]+)/stop$' -and $Method -eq 'POST') { $workflowId=[Uri]::UnescapeDataString($Matches[1]);if(-not$script:RunningJobs.ContainsKey($workflowId)){return(New-ApiError 404 'task_not_running' '任务当前没有运行。')};[void](Stop-WorkflowJob $workflowId -Silent);return(New-ApiSuccess ([pscustomobject]@{stopped=$true;workflowId=$workflowId})) }
        if ($path -match '^/web/api/running/([^/]+)$' -and $Method -eq 'GET') { $workflowId=[Uri]::UnescapeDataString($Matches[1]);$task=@(Get-WebRunningTaskItems|Where-Object{[string]$_.workflowId-eq$workflowId}|Select-Object -First 1);if($task.Count-eq0){return(New-ApiError 404 'task_not_running' '任务当前没有运行。')};return(New-ApiSuccess $task[0]) }
        return (New-ApiError 404 'route_not_found' 'Web 接口路径不存在。')
    } catch {
        return (New-ApiError 400 'web_request_failed' $_.Exception.Message)
    }
}

function ConvertTo-NormalizedDirectoryKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    try { return ([IO.Path]::GetFullPath($expanded).TrimEnd('\','/').ToLowerInvariant()) }
    catch { return $expanded.TrimEnd('\','/').ToLowerInvariant() }
}

function Read-SharedTextLines {
    param([string]$Path, [int]$MaximumLines = 40)
    $lines = New-Object System.Collections.Generic.List[string]
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try {
            while (-not $reader.EndOfStream -and $lines.Count -lt $MaximumLines) { $lines.Add($reader.ReadLine()) }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    return @($lines)
}

function Read-SharedTextTailLines {
    param([string]$Path, [int]$MaximumBytes = 8388608)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $length = [long]$stream.Length
        $count = [int][Math]::Min([long]$MaximumBytes, $length)
        $start = [Math]::Max([long]0, $length - $count)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] $count
        $offset = 0
        while ($offset -lt $count) {
            $read = $stream.Read($bytes, $offset, $count - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $offset)
        if ($start -gt 0) {
            $newline = $text.IndexOf("`n")
            if ($newline -ge 0) { $text = $text.Substring($newline + 1) } else { return @() }
        }
        return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } finally { $stream.Dispose() }
}

function Get-SessionTitleFromRecord {
    param($Record)
    if ($null -eq $Record) { return '' }
    $payload = if ($null -ne $Record.PSObject.Properties['payload']) { $Record.payload } else { $Record }
    foreach ($name in @('title','thread_name')) {
        if ($null -ne $payload -and $null -ne $payload.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$payload.$name)) { return [string]$payload.$name }
    }
    if ($null -ne $payload -and [string](Get-UiConfigValue $payload 'type' '') -eq 'message' -and [string](Get-UiConfigValue $payload 'role' '') -eq 'user') {
        foreach ($content in @($payload.content)) {
            $text = [string](Get-UiConfigValue $content 'text' '')
            if (-not [string]::IsNullOrWhiteSpace($text) -and $text -notlike '<environment_context>*') { return $text }
        }
    }
    return ''
}

function Get-CodexSessionSummaries {
    param([string]$WorkingDirectory = '', [int]$Limit = 100, [switch]$Refresh)
    $Limit = [Math]::Min(500, [Math]::Max(1, $Limit))
    if ($Refresh -or ((Get-Date) - $script:CodexSessionCacheAt).TotalSeconds -gt 15) {
        $sessions = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $script:CodexSessionsDirectory) {
            foreach ($file in @(Get-ChildItem -LiteralPath $script:CodexSessionsDirectory -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue)) {
                try {
                    $lines = @(Read-SharedTextLines $file.FullName 50)
                    if ($lines.Count -eq 0) { continue }
                    $meta = $lines[0] | ConvertFrom-Json
                    $payload = if ($null -ne $meta.PSObject.Properties['payload']) { $meta.payload } else { $meta }
                     $sessionId = [string](Get-UiConfigValue $payload 'session_id' (Get-UiConfigValue $payload 'id' ''))
                     if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
                     $forkedFromId = [string](Get-UiConfigValue $payload 'forked_from_id' '')
                     $timestamp = [string](Get-UiConfigValue $payload 'timestamp' (Get-UiConfigValue $meta 'timestamp' $file.LastWriteTimeUtc.ToString('o')))
                    $cwd = [string](Get-UiConfigValue $payload 'cwd' '')
                    $title = Get-SessionTitleFromRecord $payload
                    if ([string]::IsNullOrWhiteSpace($title)) {
                        foreach ($line in @($lines | Select-Object -Skip 1)) {
                            try { $title = Get-SessionTitleFromRecord ($line | ConvertFrom-Json) } catch { continue }
                            if (-not [string]::IsNullOrWhiteSpace($title)) { break }
                        }
                    }
                    $titleIsFallback = [string]::IsNullOrWhiteSpace($title)
                    if ($titleIsFallback) { $title = 'Codex 会话 ' + $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length)) }
                    $title = ($title -replace '\s+',' ').Trim()
                    if ($title.Length -gt 160) { $title = $title.Substring(0,160) + '...' }
                     $sessions.Add([pscustomobject]@{ time=$timestamp; title=$title; session_id=$sessionId; forked_from_id=$forkedFromId; working_directory=$cwd; source=[string](Get-UiConfigValue $payload 'source' ''); file=$file.FullName; last_write_time=$file.LastWriteTimeUtc.ToString('o'); title_is_fallback=$titleIsFallback })
                } catch { }
            }
        }
        $deduplicated = New-Object System.Collections.Generic.List[object]
        foreach ($group in @($sessions | Group-Object session_id)) {
            $ordered = @($group.Group | Sort-Object @{Expression={try{[datetime]$_.last_write_time}catch{[datetime]::MinValue}};Descending=$true})
            if ($ordered.Count -eq 0) { continue }
            $recent = $ordered[0]
            $titleRecord = @($ordered | Where-Object { -not [bool]$_.title_is_fallback } | Select-Object -First 1)
            if ($titleRecord.Count -eq 0) { $titleRecord = @($recent) }
            $directoryRecord = @($ordered | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.working_directory) } | Select-Object -First 1)
            if ($directoryRecord.Count -eq 0) { $directoryRecord = @($recent) }
             $sourceRecord = @($ordered | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.source) } | Select-Object -First 1)
             if ($sourceRecord.Count -eq 0) { $sourceRecord = @($recent) }
             $forkRecord = @($ordered | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.forked_from_id) } | Select-Object -First 1)
             if ($forkRecord.Count -eq 0) { $forkRecord = @($recent) }
             $deduplicated.Add([pscustomobject]@{
                time = [string]$recent.time
                title = [string]$titleRecord[0].title
                 session_id = [string]$recent.session_id
                 forked_from_id = [string]$forkRecord[0].forked_from_id
                 working_directory = [string]$directoryRecord[0].working_directory
                source = [string]$sourceRecord[0].source
                file = [string]$recent.file
                last_write_time = [string]$recent.last_write_time
            })
        }
        $script:CodexSessionCache = @($deduplicated | Sort-Object @{Expression={try{[datetime]$_.last_write_time}catch{[datetime]::MinValue}};Descending=$true}, @{Expression={try{[datetime]$_.time}catch{[datetime]::MinValue}};Descending=$true})
        $script:CodexSessionCacheAt = Get-Date
    }
    $directoryKey = if([string]::IsNullOrWhiteSpace($WorkingDirectory)){''}else{ConvertTo-NormalizedDirectoryKey $WorkingDirectory}
    $result = New-Object System.Collections.Generic.List[object]
    foreach($record in @($script:CodexSessionCache)){
        if(-not[string]::IsNullOrWhiteSpace($directoryKey)-and(ConvertTo-NormalizedDirectoryKey ([string]$record.working_directory))-ne$directoryKey){continue}
        $result.Add($record)
        if($result.Count-ge$Limit){break}
    }
    return $result.ToArray()
}

function Get-CodexSessionRecord {
    param([string]$SessionId, [switch]$Refresh)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }
    if($Refresh-or((Get-Date)-$script:CodexSessionCacheAt).TotalSeconds-gt15){[void](Get-CodexSessionSummaries '' 1 -Refresh:$Refresh)}
    foreach($record in @($script:CodexSessionCache)){
        if([string]$record.session_id-eq$SessionId){return $record}
    }
    return $null
}

function Get-CodexMessageText {
    param($Content)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Content)) {
        if ($item -is [string]) { if (-not [string]::IsNullOrWhiteSpace($item)) { $parts.Add($item) }; continue }
        foreach ($name in @('text','message')) {
            $value = [string](Get-UiConfigValue $item $name '')
            if (-not [string]::IsNullOrWhiteSpace($value)) { $parts.Add($value); break }
        }
    }
    return ($parts -join "`r`n").Trim()
}

function Test-CodexConversationDisplayMessage {
    param([string]$Role,[string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){return $false}
    $value=$Text.TrimStart()
    if($Role-eq'user'-and$value.StartsWith('Warning: apply_patch was requested via shell.',[StringComparison]::OrdinalIgnoreCase)){return $false}
    if($Role-eq'assistant'-and$value-match '^诊断信息\s*[:：]'){return $false}
    return $true
}

function ConvertFrom-CodexConversationLines {
    param([string[]]$Lines)
    $messages = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        $payload = Get-UiConfigValue $entry 'payload' $null
        if ($null -eq $payload) { continue }
        $entryType = [string](Get-UiConfigValue $entry 'type' '')
        $payloadType = [string](Get-UiConfigValue $payload 'type' '')
        $role = ''
        $text = ''
        if ($entryType -eq 'event_msg' -and $payloadType -eq 'user_message') {
            $role = 'user'; $text = [string](Get-UiConfigValue $payload 'message' '')
        } elseif ($entryType -eq 'event_msg' -and $payloadType -eq 'agent_message') {
            $role = 'assistant'; $text = [string](Get-UiConfigValue $payload 'message' '')
        } elseif ($entryType -eq 'event_msg' -and $payloadType -eq 'task_complete') {
            $role = 'assistant'; $text = [string](Get-UiConfigValue $payload 'last_agent_message' '')
        } elseif ($entryType -eq 'response_item' -and $payloadType -eq 'message') {
            $role = [string](Get-UiConfigValue $payload 'role' '')
            if($role-eq'user'){continue}
            $text = Get-CodexMessageText (Get-UiConfigValue $payload 'content' @())
        }
        if ($role -notin @('user','assistant') -or [string]::IsNullOrWhiteSpace($text) -or $text.TrimStart().StartsWith('<environment_context>')) { continue }
        if ($role -eq 'user' -and $text -match '(?s)^You are (?:使驾 AI|Workflow AI).*?User request:\s*(.+)$') { $text = $Matches[1].Trim() }
        if(-not(Test-CodexConversationDisplayMessage $role $text)){continue}
        $messages.Add([pscustomobject]@{ Role=$role; Text=(Limit-CodexConversationMessageText $text.Trim() $script:CodexConversationSnapshotMaxMessageCharacters); Time=[string](Get-UiConfigValue $entry 'timestamp' '') })
    }
    return $messages.ToArray()
}

function Read-CodexConversationDelta {
    param([string]$Path, [long]$Offset = -1, [int]$InitialMaximumBytes = 8388608)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $length = [long]$stream.Length
        $initial = $Offset -lt 0 -or $Offset -gt $length
        $maximumBytes = [long][Math]::Max(1048576, $InitialMaximumBytes)
        $start = if ($initial) { [Math]::Max([long]0, $length - $maximumBytes) } else { $Offset }
        $windowed = $length - $start -gt $maximumBytes
        if ($windowed) { $start = [Math]::Max([long]0, $length - $maximumBytes) }
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $count = [int][Math]::Min($maximumBytes, $length - $start)
        $bytes = New-Object byte[] $count
        $readOffset = 0
        while ($readOffset -lt $count) {
            $read = $stream.Read($bytes, $readOffset, $count - $readOffset)
            if ($read -le 0) { break }
            $readOffset += $read
        }
        $first = 0
        if (($initial -or $windowed) -and $start -gt 0) {
            while ($first -lt $readOffset -and $bytes[$first] -ne 10) { $first++ }
            if ($first -lt $readOffset) { $first++ }
        }
        $lastNewline = -1
        for ($index = $readOffset - 1; $index -ge $first; $index--) { if ($bytes[$index] -eq 10) { $lastNewline = $index; break } }
        if ($lastNewline -lt $first) { return [pscustomobject]@{ Offset=$start; FileLength=$length; Lines=@(); Initial=($initial -or $windowed) } }
        $text = [Text.Encoding]::UTF8.GetString($bytes, $first, ($lastNewline - $first + 1))
        return [pscustomobject]@{ Offset=($start + $lastNewline + 1); FileLength=$length; Lines=@($text.Split([char]10) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }); Initial=($initial -or $windowed) }
    } finally { $stream.Dispose() }
}

function Get-CodexConversationTail {
    param($Items,[int]$Limit=80)
    if($null-eq$Items-or$Limit-le0){return ,[object[]]@()}
    $source=@($Items)
    $count=[int]$source.Count
    if($count-le$Limit){return ,$source}
    $result=New-Object object[] $Limit
    [Array]::Copy($source,$count-$Limit,$result,0,$Limit)
    return ,$result
}

function Get-CodexSessionConversation {
    param([string]$SessionId, [int]$Limit = 80, [switch]$Refresh)
    $snapshot = if ($script:CodexConversationSnapshots.ContainsKey($SessionId)) { $script:CodexConversationSnapshots[$SessionId]; $script:CodexConversationSnapshotAccess[$SessionId] = Get-Date } else { $null }
    $record = $null
    if ($Refresh) { $record = Get-CodexSessionRecord $SessionId -Refresh }
    if ($null -eq $record -and $null -ne $snapshot -and $null -ne $snapshot.Session) { $record = $snapshot.Session }
    if ($null -eq $record) { $record = Get-CodexSessionRecord $SessionId }
    if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.file) -or -not (Test-Path -LiteralPath ([string]$record.file))) {
        return [pscustomobject]@{ Found=$false; Session=$record; Messages=@(); AddedMessages=@(); Reset=$false }
    }
    $path = [string]$record.file
    try {
        $sameFile = $null -ne $snapshot -and [string]$snapshot.Path -eq $path
        if($sameFile){
            $currentLength=[long]([IO.FileInfo]$path).Length
            $snapshotLength=[long](Get-UiConfigValue $snapshot 'FileLength' -1)
            if($snapshotLength-eq$currentLength){
                $snapshot.Session=$record
                $script:CodexConversationSnapshotAccess[$SessionId]=Get-Date
                $script:CodexConversationSnapshotNoChangeHits++
                $tail=Get-CodexConversationTail (Get-UiConfigValue $snapshot 'Messages' @()) $Limit
                return [pscustomobject]@{Found=$true;Session=$record;Messages=$tail;AddedMessages=[object[]]@();Reset=$false;Snapshot=$snapshot;Unchanged=$true}
            }
        }
        $offset = if ($sameFile) { [long]$snapshot.Offset } else { [long]-1 }
        $delta = Read-CodexConversationDelta $path $offset
        $messages = New-Object System.Collections.Generic.List[object]
        if ($sameFile -and -not $delta.Initial) { foreach ($item in @($snapshot.Messages)) { $messages.Add($item) } }
        $pending = New-Object System.Collections.Generic.List[object]
        if ($sameFile -and -not $delta.Initial) { foreach ($item in @(Get-UiConfigValue $snapshot 'PendingMessages' @())) { $pending.Add($item) } }
        $added = New-Object System.Collections.Generic.List[object]
        foreach ($message in @(ConvertFrom-CodexConversationLines $delta.Lines)) {
            $pendingIndex = -1
            for ($pendingItemIndex = 0; $pendingItemIndex -lt $pending.Count; $pendingItemIndex++) {
                $pendingItem = $pending[$pendingItemIndex]
                if ([string]$pendingItem.Role -eq [string]$message.Role -and [string]$pendingItem.Text -eq [string]$message.Text) { $pendingIndex = $pendingItemIndex; break }
            }
            if ($pendingIndex -ge 0) { $pending.RemoveAt($pendingIndex); continue }
            $last = if ($messages.Count -gt 0) { $messages[$messages.Count - 1] } else { $null }
            if ($null -ne $last -and [string]$last.Role -eq [string]$message.Role -and [string]$last.Text -eq [string]$message.Text) { continue }
            $messages.Add($message); $added.Add($message)
        }
        while ($messages.Count -gt $script:CodexConversationSnapshotMaxMessages) { $messages.RemoveAt(0) }
        for ($messageIndex = 0; $messageIndex -lt $messages.Count; $messageIndex++) {
            $message = $messages[$messageIndex]
            $messageText = [string](Get-UiConfigValue $message 'Text' '')
            if ($messageText.Length -gt $script:CodexConversationSnapshotMaxMessageCharacters) {
                $keepLength = [Math]::Max(1000, $script:CodexConversationSnapshotMaxMessageCharacters - 96)
                $messages[$messageIndex] = [pscustomobject]@{
                    Role = [string](Get-UiConfigValue $message 'Role' 'assistant')
                    Text = "[消息过长，已裁剪，仅保留末尾内容]`r`n" + $messageText.Substring([Math]::Max(0, $messageText.Length - $keepLength))
                    Time = [string](Get-UiConfigValue $message 'Time' '')
                }
            }
        }
        Trim-CodexConversationMessageLists -Messages (,$messages) -Pending (,$pending) -MaximumCharacters $script:CodexConversationSnapshotMaxCharactersPerSession
        $snapshot = [pscustomobject]@{ Session=$record; Path=$path; Offset=[long]$delta.Offset; FileLength=[long]$delta.FileLength; Messages=$messages.ToArray(); PendingMessages=$pending.ToArray(); UpdatedAt=Get-Date }
        $script:CodexConversationSnapshotRebuilds++
        Set-CodexConversationSnapshotCache $SessionId $snapshot
        $tail=Get-CodexConversationTail $snapshot.Messages $Limit
        return [pscustomobject]@{ Found=$true; Session=$record; Messages=$tail; AddedMessages=$added.ToArray(); Reset=(-not $sameFile -or $delta.Initial); Snapshot=$snapshot; Unchanged=$false }
    } catch { return [pscustomobject]@{ Found=$false; Session=$record; Messages=@(); AddedMessages=@(); Reset=$false; Error=$_.Exception.Message } }
}

function Get-ApiProjectItems {
    $items = New-Object System.Collections.ArrayList
    $ungrouped = @($script:Workflows | Where-Object { [string](Get-UiConfigValue $_ 'ProjectId' '') -eq '' })
    [void]$items.Add([pscustomobject]@{ id=''; name='无项目'; defaultWorkingDirectory=''; codexSessionId=''; codexModel=''; codexSessions=@(); updatedAt=''; workflowCount=$ungrouped.Count; workflows=@($ungrouped | ForEach-Object { [pscustomobject]@{ id=[string]$_.Id; name=[string]$_.Name; enabled=[bool]$_.Enabled; updatedAt=[string](Get-UiConfigValue $_ 'UpdatedAt' '') } }) })
    foreach ($project in @($script:Projects | Sort-Object @{Expression={try{[datetime]$_.UpdatedAt}catch{[datetime]::MinValue}};Descending=$true}, @{Expression={$_.Name};Descending=$false})) {
        $projectWorkflows = @($script:Workflows | Where-Object { [string](Get-UiConfigValue $_ 'ProjectId' '') -eq [string]$project.Id })
        $apiSessions=@(Get-ProjectCodexSessions $project|ForEach-Object{[pscustomobject]@{sessionId=[string]$_.SessionId;codexModel=[string]$_.CodexModel;description=[string]$_.Description}})
        [void]$items.Add([pscustomobject]@{ id=[string]$project.Id; name=[string]$project.Name; defaultWorkingDirectory=[string]$project.DefaultWorkingDirectory; codexSessionId=[string]$project.CodexSessionId; codexModel=[string](Get-UiConfigValue $project 'CodexModel' ''); codexSessions=$apiSessions; updatedAt=[string]$project.UpdatedAt; workflowCount=$projectWorkflows.Count; workflows=@($projectWorkflows | ForEach-Object { [pscustomobject]@{ id=[string]$_.Id; name=[string]$_.Name; enabled=[bool]$_.Enabled; updatedAt=[string](Get-UiConfigValue $_ 'UpdatedAt' '') } }) })
    }
    return @($items)
}

function ConvertFrom-ApiProjectCodexSessions {
    param($Value)
    $sessions=New-Object System.Collections.ArrayList;$seen=@{}
    foreach($item in @($Value)){
        $session=Normalize-ProjectCodexSession $item
        if($null-eq$session){continue}
        if([string]::IsNullOrWhiteSpace([string]$session.SessionId)){throw 'codexSessions 中每一行都必须包含 sessionId。'}
        $key=([string]$session.SessionId).ToLowerInvariant();if($seen.ContainsKey($key)){throw ('codexSessions 包含重复 sessionId：'+[string]$session.SessionId)};$seen[$key]=$true
        if([string]::IsNullOrWhiteSpace([string]$session.Description)){$session.Description='无描述'}
        [void]$sessions.Add($session)
    }
    return @($sessions)
}

function Update-ApiUiAfterMutation {
    param([string]$ProjectId = '', [string]$WorkflowId = '')
    if ($null -eq $script:MainForm -or $script:MainForm.IsDisposed) { return }
    if (-not [string]::IsNullOrWhiteSpace($ProjectId)) { $script:CurrentProject = Get-ProjectById $ProjectId }
    if (-not [string]::IsNullOrWhiteSpace($WorkflowId)) { $script:CurrentWorkflow = Find-WorkflowById $WorkflowId }
    Refresh-ProjectSelector
    if ($null -ne $script:Canvas) { $script:Canvas.Invalidate() }
}

function Invoke-WorkflowApiOperation {
    param([string]$Method, [string]$Target, [string]$Body = '', [hashtable]$Headers = @{})
    $Method = $Method.ToUpperInvariant()
    $uri = [Uri]('http://127.0.0.1' + $Target)
    $path = $uri.AbsolutePath.TrimEnd('/'); if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }
    $query = Get-ApiQueryMap $uri.Query
    if ($Headers.ContainsKey('Origin')) {
        $origin = [string]$Headers['Origin']
        if ($origin -notin @("http://127.0.0.1:$($script:ApiPort)","http://localhost:$($script:ApiPort)")) { return (New-ApiError 403 'cross_origin_forbidden' '不接受来自网页的跨源请求。') }
    }
    if ($path -eq '/api/system/restart' -and $Method -in @('GET','POST')) {
        if (Request-WorkflowManagerRestart) {
            return (New-ApiSuccess ([pscustomobject]@{ requested=$true; message='Restart requested.' }) 202)
        }
        return (New-ApiError 503 'restart_unavailable' 'Restart is unavailable.')
    }

    if ($path -eq '/api/health' -and $Method -eq 'GET') { return (New-ApiSuccess ([pscustomobject]@{ service='使驾 API'; version='1'; port=$script:ApiPort; bind='127.0.0.1'; authentication='none' })) }

    try {
        if ($path -eq '/api/projects' -and $Method -eq 'GET') {
            $projects = @(Get-ApiProjectItems)
            return (New-ApiSuccess ([pscustomobject]@{ projects=$projects; count=$projects.Count }))
        }
        if ($path -eq '/api/codex/sessions' -and $Method -eq 'GET') {
            $limit = 100; if ($query.ContainsKey('limit')) { [void][int]::TryParse([string]$query['limit'], [ref]$limit) }
            $workingDirectory = if ($query.ContainsKey('workingDirectory')) { [string]$query['workingDirectory'] } else { '' }
            $sessions = @(Get-CodexSessionSummaries $workingDirectory $limit)
            return (New-ApiSuccess ([pscustomobject]@{ sessions=$sessions; count=$sessions.Count; workingDirectory=$workingDirectory }))
        }
        if ($path -eq '/api/projects' -and $Method -eq 'POST') {
            $payload = ConvertFrom-ApiJsonBody $Body
            $name = [string](Get-UiConfigValue $payload 'name' '')
            $directory = [string](Get-UiConfigValue $payload 'defaultWorkingDirectory' '')
            $sessionId = [string](Get-UiConfigValue $payload 'codexSessionId' '')
            $model = [string](Get-UiConfigValue $payload 'codexModel' '')
            $codexSessions=if(Test-UiConfigValue $payload 'codexSessions'){@(ConvertFrom-ApiProjectCodexSessions (Get-UiConfigValue $payload 'codexSessions' @()))}elseif(-not[string]::IsNullOrWhiteSpace($sessionId)){@([pscustomobject]@{SessionId=$sessionId;CodexModel=$model;Description='默认主会话'})}else{@()};$codexSessions=@($codexSessions)
            if ([string]::IsNullOrWhiteSpace($name)) { return (New-ApiError 400 'validation_error' 'name 不能为空。') }
            if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Directory]::Exists((Resolve-ConfiguredPath $directory))) { return (New-ApiError 400 'validation_error' 'defaultWorkingDirectory 必须是已存在的目录。') }
            $directoryKey = ConvertTo-NormalizedDirectoryKey $directory
            $duplicate = @($script:Projects | Where-Object { (ConvertTo-NormalizedDirectoryKey ([string]$_.DefaultWorkingDirectory)) -eq $directoryKey } | Select-Object -First 1)
            if ($duplicate.Count -gt 0) { return (New-ApiError 409 'project_exists' '该工作目录已经存在使驾项目。' ([pscustomobject]@{ projectId=[string]$duplicate[0].Id })) }
            $project = New-Project -Name $name -DefaultWorkingDirectory $directory -CodexSessionId $sessionId -CodexModel $model -CodexSessions $codexSessions
            $script:Projects = @($script:Projects) + $project; Save-Projects; Update-ApiUiAfterMutation ([string]$project.Id)
            return (New-ApiSuccess $project 201)
        }
        if ($path -match '^/api/projects/([^/]+)$' -and $Method -in @('PUT','PATCH')) {
            $projectId = [Uri]::UnescapeDataString($Matches[1]); $project = Get-ProjectById $projectId
            if ($null -eq $project) { return (New-ApiError 404 'project_not_found' '项目不存在。') }
            $payload = ConvertFrom-ApiJsonBody $Body
            if ($null -ne $payload.PSObject.Properties['name']) { if ([string]::IsNullOrWhiteSpace([string]$payload.name)) { return (New-ApiError 400 'validation_error' 'name 不能为空。') }; $project.Name=[string]$payload.name }
            if ($null -ne $payload.PSObject.Properties['defaultWorkingDirectory']) { $directory=[string]$payload.defaultWorkingDirectory; if ([string]::IsNullOrWhiteSpace($directory)-or-not[IO.Directory]::Exists((Resolve-ConfiguredPath $directory))){return(New-ApiError 400 'validation_error' 'defaultWorkingDirectory 必须是已存在的目录。')};$directoryKey=ConvertTo-NormalizedDirectoryKey $directory;$duplicate=@($script:Projects|Where-Object{[string]$_.Id-ne$projectId-and(ConvertTo-NormalizedDirectoryKey ([string]$_.DefaultWorkingDirectory))-eq$directoryKey}|Select-Object -First 1);if($duplicate.Count-gt0){return(New-ApiError 409 'project_exists' '该工作目录已经属于其他使驾项目。' ([pscustomobject]@{projectId=[string]$duplicate[0].Id}))};$project.DefaultWorkingDirectory=$directory }
            if(Test-UiConfigValue $payload 'codexSessions'){
                Set-ProjectCodexSessions $project @(ConvertFrom-ApiProjectCodexSessions (Get-UiConfigValue $payload 'codexSessions' @()))
            }elseif((Test-UiConfigValue $payload 'codexSessionId')-or(Test-UiConfigValue $payload 'codexModel')){
                $existingSessions=@(Get-ProjectCodexSessions $project);$legacyId=if(Test-UiConfigValue $payload 'codexSessionId'){[string](Get-UiConfigValue $payload 'codexSessionId' '')}else{[string](Get-UiConfigValue $project 'CodexSessionId' '')};$legacyModel=if(Test-UiConfigValue $payload 'codexModel'){[string](Get-UiConfigValue $payload 'codexModel' '')}else{[string](Get-UiConfigValue $project 'CodexModel' '')}
                if([string]::IsNullOrWhiteSpace($legacyId)){Set-ProjectCodexSessions $project @();$project.CodexModel=$legacyModel.Trim()}
                else{$legacyDescription=if($existingSessions.Count-gt0){[string]$existingSessions[0].Description}else{'默认主会话'};$remaining=@($existingSessions|Select-Object -Skip 1);Set-ProjectCodexSessions $project @([pscustomobject]@{SessionId=$legacyId.Trim();CodexModel=$legacyModel.Trim();Description=$legacyDescription})+$remaining}
            }
            $project.UpdatedAt=(Get-Date).ToString('o'); Save-Projects; Update-ApiUiAfterMutation $projectId
            return (New-ApiSuccess $project)
        }
        if ($path -match '^/api/projects/([^/]+)/workflows$' -and $Method -eq 'POST') {
            $projectId=[Uri]::UnescapeDataString($Matches[1]);$project=Get-ProjectById $projectId
            if($null-eq$project){return(New-ApiError 404 'project_not_found' '项目不存在。')}
            $payload=ConvertFrom-ApiJsonBody $Body;$name=[string](Get-UiConfigValue $payload 'name' '新工作任务')
            if($null-ne$payload.PSObject.Properties['workflow']){if($null-eq$payload.workflow.PSObject.Properties['Name']-or$null-eq$payload.workflow.PSObject.Properties['Nodes']-or$null-eq$payload.workflow.PSObject.Properties['Edges']){return(New-ApiError 400 'validation_error' 'workflow 必须包含 Name、Nodes 和 Edges。')};if($null-eq$payload.workflow.PSObject.Properties['Id']){$payload.workflow|Add-Member NoteProperty Id ([guid]::NewGuid().ToString())};if($null-eq$payload.workflow.PSObject.Properties['ProjectId']){$payload.workflow|Add-Member NoteProperty ProjectId $projectId};$workflow=Normalize-Workflow $payload.workflow;$workflow.Id=[guid]::NewGuid().ToString();$workflow.ProjectId=$projectId;if(-not[string]::IsNullOrWhiteSpace($name)){$workflow.Name=$name}}
            else{$workflow=New-DefaultWorkflow $name $projectId}
            $workflow.UpdatedAt=(Get-Date).ToString('o');$script:Workflows=@($script:Workflows)+$workflow;Save-Workflows;Update-ApiUiAfterMutation $projectId ([string]$workflow.Id)
            return(New-ApiSuccess $workflow 201)
        }
        if ($path -match '^/api/projects/([^/]+)/workflows/([^/]+)$') {
            $projectId=[Uri]::UnescapeDataString($Matches[1]);$workflowId=[Uri]::UnescapeDataString($Matches[2]);$project=Get-ProjectById $projectId
            if($null-eq$project){return(New-ApiError 404 'project_not_found' '项目不存在。')}
            $workflow=@($script:Workflows|Where-Object{[string]$_.Id-eq$workflowId-and[string](Get-UiConfigValue $_ 'ProjectId' '')-eq$projectId}|Select-Object -First 1)
            if($workflow.Count-eq0){return(New-ApiError 404 'workflow_not_found' '该项目下不存在此工作流。')}
            if($Method-eq'GET'){return(New-ApiSuccess $workflow[0])}
            if($Method-eq'PUT'){$payload=ConvertFrom-ApiJsonBody $Body;$candidate=if($null-ne$payload.PSObject.Properties['workflow']){$payload.workflow}else{$payload};if($null-eq$candidate.PSObject.Properties['Name']-or$null-eq$candidate.PSObject.Properties['Nodes']-or$null-eq$candidate.PSObject.Properties['Edges']){return(New-ApiError 400 'validation_error' '完整工作流必须包含 Name、Nodes 和 Edges。')};if($null-eq$candidate.PSObject.Properties['Id']){$candidate|Add-Member NoteProperty Id $workflowId}else{$candidate.Id=$workflowId};if($null-eq$candidate.PSObject.Properties['ProjectId']){$candidate|Add-Member NoteProperty ProjectId $projectId}else{$candidate.ProjectId=$projectId};$candidate=Normalize-Workflow $candidate;$candidate.UpdatedAt=(Get-Date).ToString('o');$script:Workflows=@($script:Workflows|ForEach-Object{if([string]$_.Id-eq$workflowId){$candidate}else{$_}});Save-Workflows;Update-ApiUiAfterMutation $projectId $workflowId;return(New-ApiSuccess $candidate)}
            if($Method-eq'DELETE'){$script:Workflows=@($script:Workflows|Where-Object{[string]$_.Id-ne$workflowId});if($null-ne$script:CurrentWorkflow-and[string]$script:CurrentWorkflow.Id-eq$workflowId){$script:CurrentWorkflow=$null};Save-Workflows;Update-ApiUiAfterMutation $projectId;return(New-ApiSuccess ([pscustomobject]@{deleted=$true;workflowId=$workflowId;projectId=$projectId}))}
        }
        return (New-ApiError 404 'route_not_found' '接口路径不存在。')
    } catch {
        return (New-ApiError 400 'request_failed' $_.Exception.Message ([pscustomobject]@{ stack=$_.ScriptStackTrace }))
    }
}

function Invoke-PendingWorkflowApiRequests {
    if ($null -eq $script:ApiServer) { return }
    $request = $null
    while ($script:ApiServer.TryDequeue([ref]$request)) {
        try {
            $headers = @{}; foreach ($pair in $request.Headers.GetEnumerator()) { $headers[[string]$pair.Key] = [string]$pair.Value }
            $response = Invoke-WorkflowApiOperation ([string]$request.Method) ([string]$request.Target) ([string]$request.Body) $headers
            $request.ResponseStatusCode = [int]$response.StatusCode; $request.ResponseBody = [string]$response.Body
        } catch {
            $errorResponse = New-ApiError 500 'internal_error' $_.Exception.Message
            $request.ResponseStatusCode=[int]$errorResponse.StatusCode;$request.ResponseBody=[string]$errorResponse.Body
        } finally { $request.Completed.Set(); $request=$null }
    }
}

function Get-WorkflowManagerExecutablePath {
    try {
        $currentPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($currentPath) -and [IO.Path]::GetFileNameWithoutExtension($currentPath) -ieq 'WorkflowManager') { return [IO.Path]::GetFullPath($currentPath) }
    } catch { }
    $candidate = Join-Path $script:ApplicationDirectory 'WorkflowManager.exe'
    try { return [IO.Path]::GetFullPath($candidate) } catch { return $candidate }
}

function Get-WorkflowManagerListeningProcessIds {
    param([int]$Port)
    $ids = New-Object System.Collections.Generic.List[int]
    try {
        foreach ($connection in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)) {
            $processId = 0
            if ([int]::TryParse([string](Get-UiConfigValue $connection 'OwningProcess' 0), [ref]$processId) -and $processId -gt 0 -and -not $ids.Contains($processId)) { [void]$ids.Add($processId) }
        }
    } catch { }
    if ($ids.Count -eq 0) {
        try {
            foreach ($line in @(netstat -ano -p tcp 2>$null)) {
                if ([string]$line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and [int]$Matches[1] -eq $Port) {
                    $processId = [int]$Matches[2]
                    if ($processId -gt 0 -and -not $ids.Contains($processId)) { [void]$ids.Add($processId) }
                }
            }
        } catch { }
    }
    return @($ids)
}

function Test-WorkflowTcpPortAvailable {
    param([int]$Port, [string]$BindAddress = '127.0.0.1')
    if ($Port -lt 1 -or $Port -gt 65535) { return $false }
    $listener = $null
    try {
        $address = [Net.IPAddress]::Parse($BindAddress)
        $listener = New-Object Net.Sockets.TcpListener($address, $Port)
        $listener.Start()
        return $true
    } catch { return $false }
    finally { if ($null -ne $listener) { try { $listener.Stop() } catch { } } }
}

function Test-IsWorkflowManagerProcess {
    param($Process, [string]$ExpectedPath)
    if ($null -eq $Process) { return $false }
    $expected = ''
    try { $expected = [IO.Path]::GetFullPath($ExpectedPath) } catch { $expected = $ExpectedPath }
    $expectedDirectory = ''
    try { $expectedDirectory = [IO.Path]::GetDirectoryName($expected) } catch { }
    $processPath = ''
    try { $processPath = [string]$Process.Path } catch { }
    if (-not [string]::IsNullOrWhiteSpace($processPath)) {
        try {
            $processPath = [IO.Path]::GetFullPath($processPath)
            if ([string]::Equals($processPath, $expected, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            if (-not [string]::IsNullOrWhiteSpace($expectedDirectory) -and [string]::Equals([IO.Path]::GetDirectoryName($processPath), $expectedDirectory, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileNameWithoutExtension($processPath) -in @('WorkflowManager','WorkflowManager.next')) { return $true }
        } catch { }
    }
    return $false
}

function Clear-WorkflowManagerPortOccupancy {
    param([int]$Port, [string]$BindAddress = '127.0.0.1')
    if (Test-WorkflowTcpPortAvailable $Port $BindAddress) { return $true }
    $currentProcessId = 0; try { $currentProcessId = [Diagnostics.Process]::GetCurrentProcess().Id } catch { }
    $expectedPath = Get-WorkflowManagerExecutablePath
    $owners = @(Get-WorkflowManagerListeningProcessIds $Port)
    foreach ($processId in $owners) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            Write-WorkflowLog ('端口 ' + $Port + ' 的监听进程 PID ' + $processId + ' 已无法查询，暂不强制处理。') 'WARN'
            continue
        }
        if ($currentProcessId -gt 0 -and [int]$process.Id -eq $currentProcessId) {
            Write-WorkflowLog ('Port ' + $Port + ' is owned by the current WorkflowManager process; cleanup skipped.') 'WARN'
            continue
        }

        if (Test-IsWorkflowManagerProcess $process $expectedPath) {
            Write-WorkflowLog ('清理使驾残留监听进程：PID ' + $processId + '，端口 ' + $Port) 'WARN'
            Stop-ChildProcessTree ([int]$process.Id)
        } else {
            Write-WorkflowLog ('端口 ' + $Port + ' 被其它进程占用，已跳过：PID ' + $processId + ' ' + [string]$process.ProcessName) 'WARN'
        }
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (Test-WorkflowTcpPortAvailable $Port $BindAddress) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Start-WorkflowManagerServerWithRecovery {
    param([string]$ServerName, [string]$BindAddress, [int]$Port, [int]$Attempts = 5)
    $lastError = ''
    for ($attempt = 1; $attempt -le [Math]::Max(1, $Attempts); $attempt++) {
        if (-not (Test-WorkflowTcpPortAvailable $Port $BindAddress)) { [void](Clear-WorkflowManagerPortOccupancy $Port $BindAddress) }
        $server = New-Object WorkflowApiServer
        $server.ServerName = $ServerName
        try {
            $server.Start($BindAddress, $Port)
            return $server
        } catch {
            $lastError = [string]$_.Exception.Message
            try { $server.Dispose() } catch { }
            if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds (250 * $attempt) }
        }
    }
    throw ('端口 ' + $Port + ' 启动失败：' + $lastError)
}

function Invoke-PendingWorkflowWebRequests {
    if ($null -eq $script:WebApiServer) { return }
    $request = $null
    while ($script:WebApiServer.TryDequeue([ref]$request)) {
        try {
            $headers=@{};foreach($pair in $request.Headers.GetEnumerator()){$headers[[string]$pair.Key]=[string]$pair.Value}
            $response=Invoke-WorkflowWebOperation ([string]$request.Method) ([string]$request.Target) ([string]$request.Body) $headers
            $request.ResponseStatusCode=[int]$response.StatusCode;$request.ResponseContentType=[string](Get-UiConfigValue $response 'ResponseContentType' 'application/json; charset=utf-8');$request.ResponseBody=[string]$response.Body
        }catch{$errorResponse=New-ApiError 500 'internal_error' $_.Exception.Message;$request.ResponseStatusCode=[int]$errorResponse.StatusCode;$request.ResponseBody=[string]$errorResponse.Body}
        finally{$request.Completed.Set();$request=$null}
    }
}

function Start-WebApiServer {
    if ($null -ne $script:WebApiServer) { return $true }
    $enabled=[bool](Get-UiConfigValue $script:GlobalSettings 'WebEnabled' $false);if(-not$enabled){return $false}
    $accessCode=[string](Get-UiConfigValue $script:GlobalSettings 'WebAccessCode' '');if([string]::IsNullOrWhiteSpace($accessCode)){Write-WorkflowLog 'Web 未启动：访问码为空。' 'WARN';return $false}
    $port=0;if(-not[int]::TryParse([string](Get-UiConfigValue $script:GlobalSettings 'WebPort' $script:WebApiPort),[ref]$port)-or$port-lt1024-or$port-gt65535){$port=$script:WebApiPort}
    try{$server=Start-WorkflowManagerServerWithRecovery 'web' '0.0.0.0' $port 5;$script:WebApiPort=$server.Port;$script:WebApiServer=$server;Write-WorkflowLog ('Web 已启动：http://0.0.0.0:'+[string]$server.Port+'（需要访问码）');return $true}catch{Write-WorkflowLog ('Web 启动失败：'+$_.Exception.Message) 'ERROR';return $false}
}

function Stop-WebApiServer {
    if($null-ne$script:WebApiServer){try{$script:WebApiServer.Dispose()}catch{};$script:WebApiServer=$null}
    $script:WebApiSessions=@{}
}

function Sync-WebApiServer {
    $enabled=[bool](Get-UiConfigValue $script:GlobalSettings 'WebEnabled' $false)
    $configuredPort=0
    [void][int]::TryParse([string](Get-UiConfigValue $script:GlobalSettings 'WebPort' $script:WebApiPort),[ref]$configuredPort)
    if(-not$enabled){Stop-WebApiServer;return}
    if($null-ne$script:WebApiServer-and$configuredPort-gt0-and[int]$script:WebApiServer.Port-eq$configuredPort){return}
    Stop-WebApiServer
    [void](Start-WebApiServer)
}

function Request-WorkflowManagerRestart {
    if ($script:Exiting) { return $true }
    if ($null -eq $script:MainForm -or $script:MainForm.IsDisposed) { return $false }
    try {
        $callback = [Action]({
            if (-not $script:Exiting) { Exit-WorkflowManager }
        })
        if (-not $script:MainForm.IsHandleCreated) { return $false }
        [void]$script:MainForm.BeginInvoke($callback)
        return $true
    } catch { return $false }
}

function Start-WorkflowApiServer {
    if ($null -ne $script:ApiServer) { return }
    try {
        $server = Start-WorkflowManagerServerWithRecovery 'local' '127.0.0.1' ([int]$script:ApiPort) 5
        $script:ApiPort = $server.Port
        $script:ApiServer = $server
        Write-WorkflowLog ("Local API started: http://127.0.0.1:" + [string]$script:ApiPort)
        return
    } catch {
        Write-WorkflowLog ("Local API start failed: " + $_.Exception.Message) 'ERROR'
        return
    }
    if ($null -ne $script:ApiServer) { return }
    $server = New-Object WorkflowApiServer
    try { $server.Start($script:ApiPort); $script:ApiServer=$server; Write-WorkflowLog "本地 API 已启动：http://127.0.0.1:$($script:ApiPort)" }
    catch { $server.Dispose(); Write-WorkflowLog "本地 API 启动失败：$($_.Exception.Message)" 'ERROR' }
}

function Stop-WorkflowApiServer {
    if ($null -ne $script:ApiTimer) { $script:ApiTimer.Stop(); $script:ApiTimer.Dispose(); $script:ApiTimer=$null }
    if ($null -ne $script:ApiServer) { try { $script:ApiServer.Dispose() } catch { }; $script:ApiServer=$null }
}

function New-WorkflowNode {
    param([string]$Type, [string]$Name, [int]$X, [int]$Y, $Config = $null)
    if ($null -eq $Config) { $Config = [pscustomobject]@{} }
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Type = $Type
        Name = $Name
        X = $X
        Y = $Y
        Width = 180
        Height = 72
        Config = $Config
    }
}

function New-WorkflowEdge {
    param([string]$From, [string]$To, [string]$Branch = '')
    return [pscustomobject]@{ From = $From; To = $To; Branch = $Branch }
}

function New-DefaultWorkflow {
    param([string]$Name = '新工作任务', [string]$ProjectId = '')
    $start = New-WorkflowNode 'Start' '开始' 60 110
    $end = New-WorkflowNode 'End' '结束' 380 110
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Name = $Name
        ProjectId = $ProjectId
        Enabled = $false
        ScheduleMode = 'Loop'
        ScheduleKind = 'Interval'
        ScheduleTime = '09:00:00'
        ScheduleWeekdays = '1'
        ScheduleDayOfMonth = 1
        IntervalMinutes = 60
        NextRunUtc = (Get-Date).ToUniversalTime().AddMinutes(60).ToString('o')
        Nodes = @($start, $end)
        Edges = @(New-WorkflowEdge $start.Id $end.Id)
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function New-CodexClaimWorkflow {
    $start = New-WorkflowNode 'Start' '开始' 40 150
    $loginVariables = New-WorkflowNode 'EnvWrite' '登录变量' 270 150 ([pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'userToken'; Value = '' }, [pscustomobject]@{ Name = 'password'; Value = '' }, [pscustomobject]@{ Name = 'token'; Value = '' }) })
    $loginHeaders = '{"Content-Type":"application/json","Origin":"https://new.sharedchat.cc","Referer":"https://new.sharedchat.cc/"}'
    $loginBody = '{"userToken":"{{var.userToken}}","password":"{{var.password}}","token":"{{var.token}}"}'
    $login = New-WorkflowNode 'HttpRequest' '自动登录' 520 140 ([pscustomobject]@{ Method = 'POST'; Url = 'https://new.sharedchat.cc/frontend-api/login'; Headers = $loginHeaders; Body = $loginBody; ResponseVar = 'login'; ExpectedCode = '1' })
    $claimBody = '{"eventId":"","reason":"用于{{date:yyyy}}年{{date:MM}}月{{date:dd}}日的codex学习，感谢公益！","fingerprintCollectFailed":true,"fingerprintCollectError":"","collectedAt":"{{date:o}}"}'
    $claim = New-WorkflowNode 'HttpRequest' '领取 Codex 公益权益' 770 140 ([pscustomobject]@{ Method = 'POST'; Url = 'https://new.sharedchat.cc/frontend-api/vibe-code/codex/claim'; Headers = $loginHeaders; Body = $claimBody; ResponseVar = 'claim'; ExpectedCode = '1' })
    $balloon = New-WorkflowNode 'Balloon' '完成提醒' 1020 140 ([pscustomobject]@{ Title = 'Codex 公益权益'; Message = '自动登录和领取任务执行完成。' })
    $end = New-WorkflowNode 'End' '结束' 1270 140
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Name = 'Codex 公益权益自动领取'
        ProjectId = ''
        Enabled = $false
        ScheduleMode = 'Loop'
        ScheduleKind = 'Daily'
        ScheduleTime = '09:00:00'
        ScheduleWeekdays = '1'
        ScheduleDayOfMonth = 1
        IntervalMinutes = 1440
        NextRunUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')
        Nodes = @($start, $loginVariables, $login, $claim, $balloon, $end)
        Edges = @(
            (New-WorkflowEdge $start.Id $loginVariables.Id)
            (New-WorkflowEdge $loginVariables.Id $login.Id)
            (New-WorkflowEdge $login.Id $claim.Id)
            (New-WorkflowEdge $claim.Id $balloon.Id)
            (New-WorkflowEdge $balloon.Id $end.Id)
        )
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function New-DynamicVariableExampleWorkflow {
    $start = New-WorkflowNode 'Start' '开始' 40 140
    $command = 'powershell.exe -NoProfile -Command "Get-Random -Minimum 100000 -Maximum 999999"'
    $cmd = New-WorkflowNode 'Cmd' '生成随机数' 280 140 ([pscustomobject]@{ Command = $command; WorkingDirectory = ''; TimeoutSeconds = 30; OutputVar = 'randomResult'; FailOnError = $true })
    $balloon = New-WorkflowNode 'Balloon' '显示随机数' 540 140 ([pscustomobject]@{ Title = '动态变量示例'; Message = 'CMD 生成的随机数：{{var.randomResult.StdOut}}' })
    $end = New-WorkflowNode 'End' '结束' 800 140
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Name = '动态变量示例：CMD 随机数'
        ProjectId = ''
        Enabled = $false
        ScheduleMode = 'Loop'
        ScheduleKind = 'Interval'
        ScheduleTime = '09:00:00'
        ScheduleWeekdays = '1'
        ScheduleDayOfMonth = 1
        IntervalMinutes = 60
        NextRunUtc = (Get-Date).ToUniversalTime().AddMinutes(60).ToString('o')
        Nodes = @($start, $cmd, $balloon, $end)
        Edges = @(
            (New-WorkflowEdge $start.Id $cmd.Id)
            (New-WorkflowEdge $cmd.Id $balloon.Id)
            (New-WorkflowEdge $balloon.Id $end.Id)
        )
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function New-RandomBranchExampleWorkflow {
    $start = New-WorkflowNode 'Start' '开始' 40 160
    $cmd = New-WorkflowNode 'Cmd' '生成 1-100 随机数' 270 160 ([pscustomobject]@{ Command = 'powershell.exe -NoProfile -Command "Get-Random -Minimum 1 -Maximum 101"'; WorkingDirectory = ''; TimeoutSeconds = 30; OutputVar = 'random'; FailOnError = $true })
    $condition = New-WorkflowNode 'If' '是否大于等于 50' 520 160 ([pscustomobject]@{ Left = '{{var.random.StdOut}}'; Operator = 'GreaterOrEqual'; Right = '50'; OutputVar = 'isLucky' })
    $high = New-WorkflowNode 'Balloon' '幸运分支' 780 70 ([pscustomobject]@{ Title = '随机分支'; Message = '随机数 {{var.random.StdOut}}，进入“是”分支。' })
    $low = New-WorkflowNode 'Balloon' '普通分支' 780 250 ([pscustomobject]@{ Title = '随机分支'; Message = '随机数 {{var.random.StdOut}}，进入“否”分支。' })
    $end = New-WorkflowNode 'End' '结束' 1040 160
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString(); Name = '示例：随机数条件分支'; ProjectId = ''; Enabled = $false
        ScheduleMode = 'Loop'; ScheduleKind = 'Interval'; ScheduleTime = '09:00:00'; ScheduleWeekdays = '1'; ScheduleDayOfMonth = 1; IntervalMinutes = 60
        NextRunUtc = (Get-Date).ToUniversalTime().AddMinutes(60).ToString('o')
        Nodes = @($start,$cmd,$condition,$high,$low,$end)
        Edges = @((New-WorkflowEdge $start.Id $cmd.Id),(New-WorkflowEdge $cmd.Id $condition.Id),(New-WorkflowEdge $condition.Id $high.Id 'True'),(New-WorkflowEdge $condition.Id $low.Id 'False'),(New-WorkflowEdge $high.Id $end.Id),(New-WorkflowEdge $low.Id $end.Id))
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function New-ChecklistLoopExampleWorkflow {
    $start = New-WorkflowNode 'Start' '开始' 40 170
    $variables = New-WorkflowNode 'Variable' '准备今日清单' 270 170 ([pscustomobject]@{ Name = 'tasks'; ValueType = 'Json'; Value = '["喝一杯水","整理下载目录","阅读 10 分钟"]' })
    $loop = New-WorkflowNode 'ForEach' '逐项处理清单' 520 170 ([pscustomobject]@{ Items = '{{var.tasks}}'; ItemVariable = 'task'; IndexVariable = 'taskIndex'; ResultVariable = 'taskLoop' })
    $delay = New-WorkflowNode 'Delay' '短暂间隔' 780 60 ([pscustomobject]@{ Seconds = 0.5 })
    $itemBalloon = New-WorkflowNode 'Balloon' '显示当前事项' 1020 60 ([pscustomobject]@{ Title = '清单第 {{var.taskIndex}} 项'; Message = '{{var.task}}' })
    $loopEnd = New-WorkflowNode 'LoopEnd' '结束本次循环' 1260 60
    $summary = New-WorkflowNode 'Balloon' '清单完成提醒' 780 280 ([pscustomobject]@{ Title = '清单处理完成'; Message = '本次共处理 {{var.taskLoop.Count}} 项。' })
    $end = New-WorkflowNode 'End' '结束' 1030 280
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString(); Name = '示例：清单循环提醒'; ProjectId = ''; Enabled = $false
        ScheduleMode = 'Loop'; ScheduleKind = 'Interval'; ScheduleTime = '09:00:00'; ScheduleWeekdays = '1'; ScheduleDayOfMonth = 1; IntervalMinutes = 60
        NextRunUtc = (Get-Date).ToUniversalTime().AddMinutes(60).ToString('o')
        Nodes = @($start,$variables,$loop,$delay,$itemBalloon,$loopEnd,$summary,$end)
        Edges = @((New-WorkflowEdge $start.Id $variables.Id),(New-WorkflowEdge $variables.Id $loop.Id),(New-WorkflowEdge $loop.Id $delay.Id 'Body'),(New-WorkflowEdge $loop.Id $summary.Id 'Done'),(New-WorkflowEdge $delay.Id $itemBalloon.Id),(New-WorkflowEdge $itemBalloon.Id $loopEnd.Id),(New-WorkflowEdge $summary.Id $end.Id))
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function New-SystemSnapshotExampleWorkflow {
    $start = New-WorkflowNode 'Start' '开始' 40 150
    $command = 'powershell.exe -NoProfile -Command "$os=Get-CimInstance Win32_OperatingSystem; [pscustomobject]@{Computer=$env:COMPUTERNAME; FreeMemoryMB=[math]::Round($os.FreePhysicalMemory/1024); CapturedAt=(Get-Date).ToString(''HH:mm:ss'')} | ConvertTo-Json -Compress"'
    $cmd = New-WorkflowNode 'Cmd' '采集系统信息' 280 150 ([pscustomobject]@{ Command = $command; WorkingDirectory = ''; TimeoutSeconds = 30; OutputVar = 'systemRaw'; FailOnError = $true })
    $parse = New-WorkflowNode 'Variable' '解析 JSON 结果' 530 150 ([pscustomobject]@{ Name = 'systemInfo'; ValueType = 'Json'; Value = '{{var.systemRaw.StdOut}}' })
    $delay = New-WorkflowNode 'Delay' '等待界面稳定' 780 150 ([pscustomobject]@{ Seconds = 0.5 })
    $balloon = New-WorkflowNode 'Balloon' '显示系统快照' 1030 150 ([pscustomobject]@{ Title = '系统快照'; Message = '{{var.systemInfo.Computer}} 可用内存约 {{var.systemInfo.FreeMemoryMB}} MB（{{var.systemInfo.CapturedAt}}）' })
    $end = New-WorkflowNode 'End' '结束' 1280 150
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString(); Name = '示例：系统信息变量流转'; ProjectId = ''; Enabled = $false
        ScheduleMode = 'Loop'; ScheduleKind = 'Interval'; ScheduleTime = '09:00:00'; ScheduleWeekdays = '1'; ScheduleDayOfMonth = 1; IntervalMinutes = 60
        NextRunUtc = (Get-Date).ToUniversalTime().AddMinutes(60).ToString('o')
        Nodes = @($start,$cmd,$parse,$delay,$balloon,$end)
        Edges = @((New-WorkflowEdge $start.Id $cmd.Id),(New-WorkflowEdge $cmd.Id $parse.Id),(New-WorkflowEdge $parse.Id $delay.Id),(New-WorkflowEdge $delay.Id $balloon.Id),(New-WorkflowEdge $balloon.Id $end.Id))
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function Normalize-Workflow {
    param($Workflow)
    if ($null -eq $Workflow.Id) { $Workflow | Add-Member NoteProperty Id ([guid]::NewGuid().ToString()) }
    if ($null -eq $Workflow.Enabled) { $Workflow | Add-Member NoteProperty Enabled $false }
    if ($null -eq $Workflow.PSObject.Properties['ProjectId']) { $Workflow | Add-Member NoteProperty ProjectId '' }
    if ($null -eq $Workflow.PSObject.Properties['ScheduleMode']) { $Workflow | Add-Member NoteProperty ScheduleMode 'Loop' }
    if ($null -eq $Workflow.PSObject.Properties['ScheduleKind']) { $Workflow | Add-Member NoteProperty ScheduleKind 'Interval' }
    if ($null -eq $Workflow.PSObject.Properties['ScheduleTime']) { $Workflow | Add-Member NoteProperty ScheduleTime '09:00:00' }
    if ([string]::IsNullOrWhiteSpace([string]$Workflow.ScheduleTime)) { $Workflow.ScheduleTime = '09:00:00' }
    if ($null -eq $Workflow.PSObject.Properties['ScheduleWeekdays']) { $Workflow | Add-Member NoteProperty ScheduleWeekdays '1' }
    if ($null -eq $Workflow.PSObject.Properties['ScheduleDayOfMonth']) { $Workflow | Add-Member NoteProperty ScheduleDayOfMonth 1 }
    if ($null -eq $Workflow.IntervalMinutes) { $Workflow | Add-Member NoteProperty IntervalMinutes 60 }
    if ($null -eq $Workflow.NextRunUtc) { $Workflow | Add-Member NoteProperty NextRunUtc ((Get-Date).ToUniversalTime().AddMinutes([int]$Workflow.IntervalMinutes).ToString('o')) }
    if ([string]$Workflow.ScheduleMode -notin @('Loop','Once')) { $Workflow.ScheduleMode = 'Loop' }
    $validKinds = if ($Workflow.ScheduleMode -eq 'Once') { @('Interval','NextTime') } else { @('Interval','Daily','Weekly','Monthly') }
    if ([string]$Workflow.ScheduleKind -notin $validKinds) { $Workflow.ScheduleKind = 'Interval' }
    $Workflow.ScheduleDayOfMonth = [Math]::Min(31, [Math]::Max(1, [int]$Workflow.ScheduleDayOfMonth))
    $Workflow.Nodes = @($Workflow.Nodes)
    $Workflow.Edges = @($Workflow.Edges)
    foreach ($node in $Workflow.Nodes) {
        if ($null -eq $node.Width) { $node | Add-Member NoteProperty Width 180 }
        if ($null -eq $node.Height) { $node | Add-Member NoteProperty Height 72 }
        if ($null -eq $node.Config) { $node | Add-Member NoteProperty Config ([pscustomobject]@{}) }
        if ($node.Type -eq 'EnvRead' -or $node.Type -eq 'EnvWrite') {
            $normalizedItems = @(Get-UiEnvironmentItems $node.Config -Read:($node.Type -eq 'EnvRead'))
            if ($node.Type -eq 'EnvWrite') { $node.Config = [pscustomobject]@{ Items = @($normalizedItems); InlineEdit = [bool](Get-UiConfigValue $node.Config 'InlineEdit' $false) } }
            else { $node.Config = [pscustomobject]@{ Items = @($normalizedItems) } }
        }
        if ($node.Type -eq 'Balloon') {
            if ($null -eq $node.Config.PSObject.Properties['Title']) { $node.Config | Add-Member NoteProperty Title '工作流提醒' }
            if ($null -eq $node.Config.PSObject.Properties['Message']) { $node.Config | Add-Member NoteProperty Message '任务执行完成。' }
            if ($null -eq $node.Config.PSObject.Properties['ClickAction']) { $node.Config | Add-Member NoteProperty ClickAction 'None' }
            if ($null -eq $node.Config.PSObject.Properties['ClickTarget']) { $node.Config | Add-Member NoteProperty ClickTarget '' }
            if ([string]$node.Config.ClickAction -notin @('None','OpenPath','OpenUrl')) { $node.Config.ClickAction = 'None' }
        }
        if ($node.Type -eq 'Codex' -and $null -ne $node.Config.PSObject.Properties['CodexPath']) { $node.Config.PSObject.Properties.Remove('CodexPath') }
    }
    foreach ($controlNode in @($Workflow.Nodes | Where-Object { $_.Type -in @('If','ForEach') })) {
        $branches = if ($controlNode.Type -eq 'If') { @('True','False') } else { @('Body','Done') }
        $controlEdges = @($Workflow.Edges | Where-Object { [string]$_.From -eq [string]$controlNode.Id })
        for ($index = 0; $index -lt $controlEdges.Count; $index++) {
            if ($null -eq $controlEdges[$index].PSObject.Properties['Branch']) { $controlEdges[$index] | Add-Member NoteProperty Branch '' }
            if ([string]::IsNullOrWhiteSpace([string]$controlEdges[$index].Branch) -and $index -lt $branches.Count) { $controlEdges[$index].Branch = $branches[$index] }
        }
    }
    return $Workflow
}

function Load-Workflows {
    Ensure-DataDirectories
    if (-not (Test-Path -LiteralPath $script:WorkflowPath)) { return @(New-DefaultWorkflow) }
    try {
        $data = [IO.File]::ReadAllText($script:WorkflowPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $result = @()
        foreach ($workflow in @($data)) { $result += (Normalize-Workflow $workflow) }
        if ($result.Count -eq 0) { return @(New-DefaultWorkflow) }
        return $result
    } catch {
        Show-Message "读取工作流失败：$($_.Exception.Message)" '加载失败' ([Windows.Forms.MessageBoxIcon]::Error)
        return @(New-DefaultWorkflow)
    }
}

function Save-Workflows {
    Ensure-DataDirectories
    foreach ($workflow in @($script:Workflows)) { $workflow.UpdatedAt = (Get-Date).ToString('o') }
    Write-JsonFileAtomic $script:WorkflowPath @($script:Workflows)
    if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '工作流已保存' }
}

function Get-UniqueWorkflowCopyName {
    param([string]$SourceName, [string]$ProjectId)
    $baseName = if ([string]::IsNullOrWhiteSpace($SourceName)) { '工作任务' } else { $SourceName.Trim() }
    $existingNames = @($script:Workflows | Where-Object { [string](Get-UiConfigValue $_ 'ProjectId' '') -eq $ProjectId } | ForEach-Object { [string]$_.Name })
    $candidate = $baseName
    if($existingNames -contains $candidate){
        $candidate = $baseName + ' - 副本'
        $index = 2
        while ($existingNames -contains $candidate) { $candidate = $baseName + ' - 副本 ' + $index; $index++ }
    }
    return $candidate
}

function Copy-SelectedWorkflow {
    $workflow = if ($null -ne $script:WorkflowList -and $script:WorkflowList.SelectedIndex -ge 0) { $script:WorkflowList.SelectedItem } else { $script:CurrentWorkflow }
    if ($null -eq $workflow) { return $false }
    $script:CopiedWorkflowJson = $workflow | ConvertTo-Json -Depth 40 -Compress
    if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '已复制工作任务：' + [string]$workflow.Name }
    return $true
}

function New-CopiedWorkflow {
    param([string]$WorkflowJson, [string]$ProjectId)
    if ([string]::IsNullOrWhiteSpace($WorkflowJson)) { return $null }
    try { $copy = $WorkflowJson | ConvertFrom-Json } catch { return $null }
    $copy = Normalize-Workflow $copy
    $copy.Id = [guid]::NewGuid().ToString()
    $copy.ProjectId = $ProjectId
    $copy.Name = Get-UniqueWorkflowCopyName ([string]$copy.Name) $ProjectId
    $copy.Enabled = $false
    $copy.UpdatedAt = (Get-Date).ToString('o')
    $copy.NextRunUtc = (Get-NextWorkflowRunUtc $copy ([datetime]::UtcNow)).ToString('o')
    $nodeIds = @{}
    foreach ($node in @($copy.Nodes)) {
        $oldId = [string]$node.Id
        $newId = [guid]::NewGuid().ToString()
        $nodeIds[$oldId] = $newId
        $node.Id = $newId
    }
    foreach ($edge in @($copy.Edges)) {
        $from = [string]$edge.From; $to = [string]$edge.To
        if ($nodeIds.ContainsKey($from)) { $edge.From = [string]$nodeIds[$from] }
        if ($nodeIds.ContainsKey($to)) { $edge.To = [string]$nodeIds[$to] }
    }
    return $copy
}

function Paste-CopiedWorkflow {
    if ([string]::IsNullOrWhiteSpace($script:CopiedWorkflowJson)) { return $null }
    $workflow = New-CopiedWorkflow $script:CopiedWorkflowJson (Get-CurrentProjectId)
    if ($null -eq $workflow) { return $null }
    $script:Workflows = @($script:Workflows) + $workflow
    $script:CurrentWorkflow = $workflow
    Save-Workflows
    Show-WorkflowWorkspace
    Refresh-WorkflowList
    if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '已粘贴工作任务：' + [string]$workflow.Name + '（默认未启用）' }
    return $workflow
}

function Get-WorkflowMoveState {
    param($Workflow = $null)
    if ($null -eq $Workflow) {
        $Workflow = if ($null -ne $script:WorkflowList -and $script:WorkflowList.SelectedIndex -ge 0) { $script:WorkflowList.SelectedItem } else { $script:CurrentWorkflow }
    }
    if ($null -eq $Workflow) { return [pscustomobject]@{ CanMoveUp=$false; CanMoveDown=$false; GroupIndex=-1; GroupCount=0 } }
    $projectId = [string](Get-UiConfigValue $Workflow 'ProjectId' '')
    $group = @($script:Workflows | Where-Object { [string](Get-UiConfigValue $_ 'ProjectId' '') -eq $projectId })
    $groupIndex = -1
    for ($index = 0; $index -lt $group.Count; $index++) { if ([string]$group[$index].Id -eq [string]$Workflow.Id) { $groupIndex = $index; break } }
    return [pscustomobject]@{ CanMoveUp=($groupIndex -gt 0); CanMoveDown=($groupIndex -ge 0 -and $groupIndex -lt ($group.Count - 1)); GroupIndex=$groupIndex; GroupCount=$group.Count }
}

function Move-SelectedWorkflow {
    param([ValidateSet(-1,1)][int]$Direction, $Workflow = $null, [switch]$NoRefresh)
    if ($null -eq $Workflow) {
        $Workflow = if ($null -ne $script:WorkflowList -and $script:WorkflowList.SelectedIndex -ge 0) { $script:WorkflowList.SelectedItem } else { $script:CurrentWorkflow }
    }
    if ($null -eq $Workflow) { return $false }
    $projectId = [string](Get-UiConfigValue $Workflow 'ProjectId' '')
    $group = @($script:Workflows | Where-Object { [string](Get-UiConfigValue $_ 'ProjectId' '') -eq $projectId })
    $groupIndex = -1
    for ($index = 0; $index -lt $group.Count; $index++) { if ([string]$group[$index].Id -eq [string]$Workflow.Id) { $groupIndex = $index; break } }
    $targetGroupIndex = $groupIndex + $Direction
    if ($groupIndex -lt 0 -or $targetGroupIndex -lt 0 -or $targetGroupIndex -ge $group.Count) { return $false }
    $targetWorkflow = $group[$targetGroupIndex]
    $sourceIndex = -1; $targetIndex = -1
    for ($index = 0; $index -lt $script:Workflows.Count; $index++) {
        if ([string]$script:Workflows[$index].Id -eq [string]$Workflow.Id) { $sourceIndex = $index }
        if ([string]$script:Workflows[$index].Id -eq [string]$targetWorkflow.Id) { $targetIndex = $index }
    }
    if ($sourceIndex -lt 0 -or $targetIndex -lt 0) { return $false }
    $items = @($script:Workflows)
    $temporary = $items[$sourceIndex]; $items[$sourceIndex] = $items[$targetIndex]; $items[$targetIndex] = $temporary
    $script:Workflows = $items
    $script:CurrentWorkflow = $Workflow
    Save-Workflows
    if (-not $NoRefresh) { Refresh-WorkflowList }
    if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = ([string]$Workflow.Name + $(if($Direction -lt 0){' 已上移'}else{' 已下移'})) }
    return $true
}

function Invoke-WorkflowListClipboardShortcut {
    param([Windows.Forms.KeyEventArgs]$EventArgs)
    if ($null -eq $EventArgs -or $EventArgs.Handled -or -not $EventArgs.Control) { return }
    if ($EventArgs.KeyCode -eq [Windows.Forms.Keys]::C) {
        if (Copy-SelectedWorkflow) { $EventArgs.Handled=$true; $EventArgs.SuppressKeyPress=$true }
    } elseif ($EventArgs.KeyCode -eq [Windows.Forms.Keys]::V) {
        if ($null -ne (Paste-CopiedWorkflow)) { $EventArgs.Handled=$true; $EventArgs.SuppressKeyPress=$true }
    }
}

function Get-RestartWorkflowCommand {
    $target = Join-Path $script:ApplicationDirectory 'WorkflowManager.exe'
    try { $target = [IO.Path]::GetFullPath($target) } catch { }
    $settingsPath = Join-Path $script:DataDirectory 'settings.json'
    function ConvertTo-WorkflowPowerShellLiteral {
        param([string]$Value)
        return "'" + ([string]$Value).Replace("'", "''") + "'"
    }
    $innerScript = {
        $target = __TARGET__
        $settingsPath = __SETTINGS__
        $next = [IO.Path]::Combine([IO.Path]::GetDirectoryName($target), ([IO.Path]::GetFileNameWithoutExtension($target) + '.next' + [IO.Path]::GetExtension($target)))
        $root = [IO.Path]::GetDirectoryName($target)
        function Test-RestartPortAvailable {
            param([int]$Port, [string]$BindAddress = '0.0.0.0')
            $listener = $null
            try { $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($BindAddress), $Port); $listener.Start(); return $true } catch { return $false }
            finally { if ($null -ne $listener) { try { $listener.Stop() } catch { } } }
        }
        function Get-RestartListeningProcessIds {
            param([int]$Port)
            $ids = New-Object System.Collections.Generic.List[int]
            try { foreach ($line in @(netstat -ano -p tcp 2>$null)) { if ([string]$line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and [int]$Matches[1] -eq $Port) { $id=[int]$Matches[2]; if($id -gt 0 -and -not$ids.Contains($id)){[void]$ids.Add($id)} } } } catch { }
            return @($ids)
        }
        function Test-RestartOwnedProcess {
            param($Process)
            if ($null -eq $Process) { return $false }
            $path = ''
            try { $path = [IO.Path]::GetFullPath([string]$Process.Path) } catch { }
            if ([string]::IsNullOrWhiteSpace($path)) { return $false }
            return [string]::Equals($path,$target,[StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($path,$next,[StringComparison]::OrdinalIgnoreCase)
        }
        function Stop-RestartProcessTree {
            param([int]$ProcessId)
            if ($ProcessId -le 0) { return }
            try { $taskKill=Join-Path $env:WINDIR 'System32\taskkill.exe';$child=Start-Process -FilePath $taskKill -ArgumentList @('/PID',[string]$ProcessId,'/T','/F') -WindowStyle Hidden -PassThru -Wait;if($null-ne$child){$child.Dispose()} } catch { try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        }
        function Get-RestartOwnedProcesses {
            $items=New-Object System.Collections.ArrayList
            foreach($process in @(Get-Process -ErrorAction SilentlyContinue)){if(Test-RestartOwnedProcess $process){[void]$items.Add($process)}}
            return @($items)
        }
        function Wait-RestartTargetExit {
            $deadline=(Get-Date).AddSeconds(30)
            do { $running=@(Get-RestartOwnedProcesses);if($running.Count -eq 0){return $true};Start-Sleep -Milliseconds 200 } while((Get-Date)-lt$deadline)
            foreach($process in @(Get-RestartOwnedProcesses)){Stop-RestartProcessTree ([int]$process.Id)}
            return $false
        }
        function Wait-RestartPorts {
            param([int[]]$Ports)
            foreach($port in @($Ports|Where-Object{$_-gt0}|Select-Object -Unique)){
                $released=$false
                for($attempt=0;$attempt-lt120;$attempt++){
                    if(Test-RestartPortAvailable $port '0.0.0.0'){$released=$true;break}
                    foreach($processId in @(Get-RestartListeningProcessIds $port)){$process=Get-Process -Id $processId -ErrorAction SilentlyContinue;if($null-ne$process-and(Test-RestartOwnedProcess $process)){Stop-RestartProcessTree $processId}}
                    Start-Sleep -Milliseconds 150
                }
                if(-not$released){return $false}
            }
            return $true
        }
        try {
            try { Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'http://127.0.0.1:5169/api/system/restart' -TimeoutSec 3 | Out-Null } catch { }
            [void](Wait-RestartTargetExit)
            $ports=@(5169)
            try { if(Test-Path -LiteralPath $settingsPath){$settings=[IO.File]::ReadAllText($settingsPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;if([bool]$settings.WebEnabled-and[int]$settings.WebPort-gt0){$ports+=[int]$settings.WebPort}} } catch { }
            if(-not(Wait-RestartPorts $ports)){exit 4}
            $deadline=(Get-Date).AddSeconds(20)
            while(Test-Path -LiteralPath $next-and(Get-Date)-lt$deadline){try{if(Test-Path -LiteralPath $target){[IO.File]::Replace($next,$target,$null,$true)}else{Move-Item -LiteralPath $next -Destination $target -Force};break}catch{Start-Sleep -Milliseconds 250}}
            if(Test-Path -LiteralPath $next){exit 5}
            if(-not(Test-Path -LiteralPath $target)){exit 6}
            Start-Sleep -Milliseconds 350
            Start-Process -FilePath $target -WorkingDirectory $root -WindowStyle Hidden | Out-Null
        } catch { exit 9 }
    }.ToString()
    $inner = $innerScript.Replace('__TARGET__',(ConvertTo-WorkflowPowerShellLiteral $target)).Replace('__SETTINGS__',(ConvertTo-WorkflowPowerShellLiteral $settingsPath))
    $innerEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $powerShellPath=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $outerScript={
        $powerShellPath='__POWERSHELL__'
        Start-Process -FilePath $powerShellPath -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-EncodedCommand','__INNER__') -WindowStyle Hidden | Out-Null
    }.ToString()
    $outer=$outerScript.Replace('__POWERSHELL__',$powerShellPath.Replace("'","''")).Replace('__INNER__',$innerEncoded)
    $outerEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($outer))
    return 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $outerEncoded
}

function Get-RestartWorkflowPythonScriptPath {
    $candidates=@((Join-Path $script:ApplicationDirectory 'restartShiJia.py'),(Join-Path ([IO.Path]::GetDirectoryName($script:ApplicationDirectory)) 'restartShiJia.py'),'D:\桌面\fun\powerUI\workflow\restartShiJia.py')
    $existing=@($candidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)
    if($existing.Count-gt0){return [string]$existing[0]}
    return [string]$candidates[0]
}
function Upgrade-RestartWorkflow {
    $restartWorkflowName=(-join @([char]0x91CD,[char]0x542F,[char]0x4F7F,[char]0x9A7E))
    $candidate=@($script:Workflows|Where-Object{[string]$_.Name-eq$restartWorkflowName}|Select-Object -First 1)
    if($candidate.Count-eq0){return $false}
    $workflow=$candidate[0]
    $node=@($workflow.Nodes|Where-Object{[string]$_.Type-eq'Python'}|Select-Object -First 1)
    if($node.Count-eq0){$node=@($workflow.Nodes|Where-Object{[string]$_.Type-eq'Cmd'}|Select-Object -First 1)}
    if($node.Count-eq0){return $false}
    $node=$node[0];$changed=$false
    if([string]$node.Type-ne'Python'){$node.Type='Python';$changed=$true}
    if([string]$node.Name-ne'执行 Python 重启脚本'){$node.Name='执行 Python 重启脚本';$changed=$true}
    $desiredConfig=[pscustomobject]@{Mode='File';Script=(Get-RestartWorkflowPythonScriptPath);InterpreterPath='';WorkingDirectory=[string]$script:ApplicationDirectory;Arguments='';TimeoutSeconds='30';OutputVar='restartResult';FailOnError=$true}
    foreach($property in @('Mode','Script','InterpreterPath','WorkingDirectory','Arguments','TimeoutSeconds','OutputVar','FailOnError')){if([string](Get-UiConfigValue $node.Config $property '')-ne[string](Get-UiConfigValue $desiredConfig $property '')){$changed=$true;break}}
    if($changed){$node.Config=$desiredConfig;$workflow.UpdatedAt=(Get-Date).ToString('o');Save-Workflows;Write-WorkflowLog 'Restart workflow upgraded to Python restart script.'}
    return $changed
}

function Install-BuiltInWorkflowExamples {
    if (Test-Path -LiteralPath $script:ExamplesMarkerPath) { return }
    $examples = @((New-RandomBranchExampleWorkflow),(New-ChecklistLoopExampleWorkflow),(New-SystemSnapshotExampleWorkflow))
    foreach ($example in $examples) {
        if (@($script:Workflows | Where-Object { [string]$_.Name -eq [string]$example.Name }).Count -eq 0) { $script:Workflows = @($script:Workflows) + $example }
    }
    Save-Workflows
    [IO.File]::WriteAllText($script:ExamplesMarkerPath, '3', (New-Object Text.UTF8Encoding($false)))
}

function Upgrade-MainBranchBuildWorkflow {
    $project = @($script:Projects | Where-Object { [string](Get-UiConfigValue $_ 'Name' '') -eq '主分支 功能与维护' } | Select-Object -First 1)
    if ($project.Count -eq 0) { return $false }
    $workflow = @($script:Workflows | Where-Object { [string](Get-UiConfigValue $_ 'ProjectId' '') -eq [string]$project[0].Id -and [string]$_.Name -eq '构建项目' } | Select-Object -First 1)
    if ($workflow.Count -eq 0) { return $false }
    $workflow = $workflow[0]
    $commandNode = @($workflow.Nodes | Where-Object { [string]$_.Type -eq 'Cmd' } | Where-Object { [string](Get-UiConfigValue $_.Config 'Command' '') -like '*Z.py*' } | Select-Object -First 1)
    if ($commandNode.Count -eq 0) { return $false }
    $commandNode = $commandNode[0]; $changed = $false
    $optionNode = @($workflow.Nodes | Where-Object { [string]$_.Type -eq 'EnvWrite' -and [string]$_.Name -eq '构建选项' } | Select-Object -First 1)
    if ($optionNode.Count -eq 0) {
        $originalX = ConvertTo-CanvasInt $commandNode.X
        foreach ($node in @($workflow.Nodes | Where-Object { (ConvertTo-CanvasInt $_.X) -ge $originalX })) { $node.X = (ConvertTo-CanvasInt $node.X) + 320 }
        $optionNode = New-WorkflowNode 'EnvWrite' '构建选项' $originalX (ConvertTo-CanvasInt $commandNode.Y)
        foreach ($edge in @($workflow.Edges | Where-Object { [string]$_.To -eq [string]$commandNode.Id })) { $edge.To = [string]$optionNode.Id }
        $workflow.Nodes = @($workflow.Nodes) + $optionNode
        $workflow.Edges = @($workflow.Edges) + (New-WorkflowEdge ([string]$optionNode.Id) ([string]$commandNode.Id))
        $changed = $true
    } else { $optionNode = $optionNode[0] }
    $existingItems = @(Get-UiEnvironmentItems $optionNode.Config)
    $linuxItem = @($existingItems | Where-Object { [string](Get-UiConfigValue $_ 'Name' '') -eq 'PackLinux' } | Select-Object -First 1)
    $gcuItem = @($existingItems | Where-Object { [string](Get-UiConfigValue $_ 'Name' '') -eq 'PackGCU' } | Select-Object -First 1)
    $linuxValue = if ($linuxItem.Count -gt 0) { [string](Get-UiConfigValue $linuxItem[0] 'Value' 'false') } else { 'false' }
    $gcuValue = if ($gcuItem.Count -gt 0) { [string](Get-UiConfigValue $gcuItem[0] 'Value' 'true') } else { 'true' }
    $desiredConfig = [pscustomobject]@{ InlineEdit = $true; Items = @(
        [pscustomobject]@{ Name = 'PackLinux'; Label = '打包 Linux'; Value = $linuxValue; ValueType = 'Boolean' },
        [pscustomobject]@{ Name = 'PackGCU'; Label = '打包 GCU'; Value = $gcuValue; ValueType = 'Boolean' }
    ) }
    if (($optionNode.Config | ConvertTo-Json -Depth 10 -Compress) -ne ($desiredConfig | ConvertTo-Json -Depth 10 -Compress)) { $optionNode.Config = $desiredConfig; $changed = $true }
    [void](Sync-InlineVariableNodeLayout $optionNode)
    $command = [string](Get-UiConfigValue $commandNode.Config 'Command' '')
    $updatedCommand = $command
    if ($updatedCommand -notlike '*--pack-linux*') { $updatedCommand = $updatedCommand.TrimEnd() + ' --pack-linux {{var.PackLinux}}' }
    if ($updatedCommand -notlike '*--pack-gcu*') { $updatedCommand = $updatedCommand.TrimEnd() + ' --pack-gcu {{var.PackGCU}}' }
    if ($updatedCommand -ne $command) { [void](Set-UiConfigValue $commandNode.Config 'Command' $updatedCommand); $changed = $true }
    if ($changed) { $workflow.UpdatedAt = (Get-Date).ToString('o'); Save-Workflows }
    return $changed
}

function Export-WorkflowConfigurationToPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $payload = [pscustomobject]@{
        Format = 'Shijia.WorkflowManager'
        Version = 2
        ExportedAt = (Get-Date).ToString('o')
        Projects = @($script:Projects)
        Workflows = @($script:Workflows)
        GlobalSettings = $script:GlobalSettings
    }
    [IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Depth 30), [Text.Encoding]::UTF8)
}

function Import-WorkflowConfigurationFromPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $payload = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $workflowsProperty = $payload.PSObject.Properties['Workflows']
    $imported = if ($null -ne $workflowsProperty) { @($workflowsProperty.Value) } else { @($payload) }
    if ($imported.Count -eq 0) { throw '导入文件不包含工作流。' }
    $normalized = New-Object System.Collections.ArrayList
    foreach ($workflow in $imported) {
        if ($null -eq $workflow.PSObject.Properties['Name'] -or $null -eq $workflow.PSObject.Properties['Nodes'] -or $null -eq $workflow.PSObject.Properties['Edges']) { throw '导入文件包含无效的工作流结构。' }
        [void]$normalized.Add((Normalize-Workflow $workflow))
    }
    return @($normalized)
}

function Import-ApplicationConfigurationFromPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $payload = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $workflows = @(Import-WorkflowConfigurationFromPath $Path)
    $projects = @()
    if ($null -ne $payload.PSObject.Properties['Projects']) { $projects = @($payload.Projects | ForEach-Object { Normalize-Project $_ }) }
    $settings = if ($null -ne $payload.PSObject.Properties['GlobalSettings']) { Normalize-GlobalSettings $payload.GlobalSettings } else { $script:GlobalSettings }
    return [pscustomobject]@{ Workflows = $workflows; Projects = $projects; GlobalSettings = $settings }
}

function Show-ExportWorkflowConfiguration {
    $dialog = New-Object Windows.Forms.SaveFileDialog
    $dialog.Filter = 'JSON 配置 (*.json)|*.json|所有文件 (*.*)|*.*'
    $dialog.FileName = '使驾-工作流-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json'
    $dialog.Title = '导出工作流配置（文件可能包含敏感变量）'
    try {
        if ($dialog.ShowDialog($script:MainForm) -ne [Windows.Forms.DialogResult]::OK) { return }
        Export-WorkflowConfigurationToPath $dialog.FileName
        Show-Message '配置已导出。请妥善保管，其中可能包含账号或密码。' '导出完成' ([Windows.Forms.MessageBoxIcon]::Information)
    } catch {
        Show-Message ('导出配置失败：' + $_.Exception.Message) '导出失败' ([Windows.Forms.MessageBoxIcon]::Error)
    } finally {
        $dialog.Dispose()
    }
}

function Show-ImportWorkflowConfiguration {
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = 'JSON 配置 (*.json)|*.json|所有文件 (*.*)|*.*'
    $dialog.Title = '导入工作流配置'
    try {
        if ($dialog.ShowDialog($script:MainForm) -ne [Windows.Forms.DialogResult]::OK) { return }
        $imported = Import-ApplicationConfigurationFromPath $dialog.FileName
        $answer = [Windows.Forms.MessageBox]::Show("导入将替换当前全部 $($script:Workflows.Count) 个工作流和 $($script:Projects.Count) 个项目。是否继续？", '确认导入', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        $script:Workflows = @($imported.Workflows)
        $script:Projects = @($imported.Projects)
        $script:GlobalSettings = $imported.GlobalSettings
        $script:CurrentWorkflow = $null
        $script:CurrentProject = $null
        Save-Workflows
        Save-Projects
        Save-GlobalSettings
        Refresh-ProjectSelector
        Show-Message '配置已导入。' '导入完成' ([Windows.Forms.MessageBoxIcon]::Information)
    } catch {
        Show-Message ('导入配置失败：' + $_.Exception.Message) '导入失败' ([Windows.Forms.MessageBoxIcon]::Error)
    } finally {
        $dialog.Dispose()
    }
}

function Get-NodeById {
    param([string]$Id)
    return ($script:CurrentWorkflow.Nodes | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1)
}

function Get-NodeAt {
    param([int]$X, [int]$Y)
    if ($null -eq $script:CurrentWorkflow) { return $null }
    $nodes = @($script:CurrentWorkflow.Nodes)
    for ($index = $nodes.Count - 1; $index -ge 0; $index--) {
        $node = $nodes[$index]
        $nodeX = ConvertTo-CanvasInt $node.X; $nodeY = ConvertTo-CanvasInt $node.Y
        $nodeWidth = ConvertTo-CanvasInt $node.Width; $nodeHeight = ConvertTo-CanvasInt $node.Height
        if ([int]$X -ge [int]$nodeX -and [int]$X -le ([int]$nodeX + [int]$nodeWidth) -and [int]$Y -ge [int]$nodeY -and [int]$Y -le ([int]$nodeY + [int]$nodeHeight)) { return $node }
    }
    return $null
}

function Get-EdgeAt {
    param([int]$X, [int]$Y)
    if ($null -eq $script:CurrentWorkflow) { return $null }
    $edges = @($script:CurrentWorkflow.Edges)
    for ($index = $edges.Count - 1; $index -ge 0; $index--) {
        $edge = $edges[$index]
        $from = Get-NodeById ([string]$edge.From); $to = Get-NodeById ([string]$edge.To)
        if ($null -eq $from -or $null -eq $to) { continue }
        $x1 = [double](ConvertTo-CanvasInt $from.X) + [double](ConvertTo-CanvasInt $from.Width)
        $y1 = [double](ConvertTo-CanvasInt $from.Y) + ([double](ConvertTo-CanvasInt $from.Height) / 2)
        $x2 = [double](ConvertTo-CanvasInt $to.X)
        $y2 = [double](ConvertTo-CanvasInt $to.Y) + ([double](ConvertTo-CanvasInt $to.Height) / 2)
        $minX = [Math]::Min($x1, $x2); $maxX = [Math]::Max($x1, $x2)
        if ([Math]::Abs($y2 - $y1) -le 1 -and [double]$X -ge ($minX - 10) -and [double]$X -le ($maxX + 10) -and [Math]::Abs([double]$Y - $y1) -le 10) { return $edge }
        $distance = [WorkflowCanvasPanel]::DistanceToSegment([double]$X, [double]$Y, $x1, $y1, $x2, $y2)
        if ($distance -le 9) { return $edge }
    }
    return $null
}

function ConvertTo-CanvasInt {
    param($Value)
    $values = @($Value)
    if ($values.Count -eq 0) { return 0 }
    return [int]$values[$values.Count - 1]
}

function Get-CanvasDelta {
    param($Left, $Right)
    $leftInt = ConvertTo-CanvasInt $Left
    $rightInt = ConvertTo-CanvasInt $Right
    $delta = [int]$leftInt
    $delta = $delta - [int]$rightInt
    return $delta
}

function Get-CanvasMousePoint {
    param($Sender, $EventArgs)
    $control = @($Sender) | Where-Object { $_ -is [Windows.Forms.Control] } | Select-Object -Last 1
    $mouseEvent = @($EventArgs) | Where-Object { $_ -is [Windows.Forms.MouseEventArgs] } | Select-Object -Last 1
    if ($null -eq $control -or $null -eq $mouseEvent) { return $null }
    $scroll = $control.AutoScrollPosition
    $eventX = ConvertTo-CanvasInt $mouseEvent.X
    $eventY = ConvertTo-CanvasInt $mouseEvent.Y
    $scrollX = ConvertTo-CanvasInt $scroll.X
    $scrollY = ConvertTo-CanvasInt $scroll.Y
    return [pscustomobject]@{ X = Get-CanvasDelta $eventX $scrollX; Y = Get-CanvasDelta $eventY $scrollY }
}

function Get-NodeColor {
    param([string]$Type)
    switch ($Type) {
        'Start' { return [Drawing.Color]::FromArgb(22, 163, 74) }
        'End' { return [Drawing.Color]::FromArgb(220, 38, 38) }
        'HttpRequest' { return [Drawing.Color]::FromArgb(37, 99, 235) }
        'Cmd' { return [Drawing.Color]::FromArgb(8, 145, 178) }
        'Python' { return [Drawing.Color]::FromArgb(250, 204, 21) }
        'Codex' { return [Drawing.Color]::FromArgb(17, 24, 39) }
        'EnvRead' { return [Drawing.Color]::FromArgb(124, 58, 237) }
        'EnvWrite' { return [Drawing.Color]::FromArgb(147, 51, 234) }
        'Variable' { return [Drawing.Color]::FromArgb(5, 150, 105) }
        'If' { return [Drawing.Color]::FromArgb(217, 119, 6) }
        'ForEach' { return [Drawing.Color]::FromArgb(79, 70, 229) }
        'LoopEnd' { return [Drawing.Color]::FromArgb(100, 116, 139) }
        'Delay' { return [Drawing.Color]::FromArgb(14, 116, 144) }
        'Balloon' { return [Drawing.Color]::FromArgb(234, 88, 12) }
        default { return [Drawing.Color]::FromArgb(75, 85, 99) }
    }
}

function Get-NodeTypeLabel {
    param([string]$Type)
    switch ($Type) {
        'Start' { return '开始' }
        'End' { return '结束' }
        'HttpRequest' { return '网络请求' }
        'Cmd' { return 'CMD 命令' }
        'Python' { return 'Python 脚本' }
        'Codex' { return '调用 Codex' }
        'EnvRead' { return '变量读取' }
        'EnvWrite' { return '变量写入' }
        'Variable' { return '变量赋值' }
        'If' { return '条件判断' }
        'ForEach' { return '遍历循环' }
        'LoopEnd' { return '循环结束' }
        'Delay' { return '延时等待' }
        'Balloon' { return 'Windows 气泡' }
        default { return $Type }
    }
}

function Add-WorkflowEdge {
    param([string]$From, [string]$To)
    if ($From -eq $To) { return }
    $exists = @($script:CurrentWorkflow.Edges | Where-Object { $_.From -eq $From -and $_.To -eq $To }).Count -gt 0
    if (-not $exists) {
        $branch = ''
        $sourceNode = Get-NodeById $From
        if ($null -ne $sourceNode -and $sourceNode.Type -in @('If','ForEach')) {
            $branches = if ($sourceNode.Type -eq 'If') { @('True','False') } else { @('Body','Done') }
            $used = @($script:CurrentWorkflow.Edges | Where-Object { [string]$_.From -eq $From } | ForEach-Object { [string](Get-UiConfigValue $_ 'Branch' '') })
            $branch = @($branches | Where-Object { $_ -notin $used } | Select-Object -First 1)
            if ($branch.Count -eq 0) {
                Show-Message "$((Get-NodeTypeLabel $sourceNode.Type))节点最多只能连接两条输出。" '连接节点' ([Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            $branch = [string]$branch[0]
        }
        $script:CurrentWorkflow.Edges = @($script:CurrentWorkflow.Edges) + (New-WorkflowEdge $From $To $branch)
        $script:CurrentWorkflow.UpdatedAt = (Get-Date).ToString('o')
        $script:Canvas.Invalidate()
    }
}

function Remove-SelectedNode {
    if ($null -eq $script:SelectedNode -or $null -eq $script:CurrentWorkflow) { return }
    if ($script:SelectedNode.Type -eq 'Start' -or $script:SelectedNode.Type -eq 'End') {
        $sameTypeCount = @($script:CurrentWorkflow.Nodes | Where-Object { $_.Type -eq $script:SelectedNode.Type }).Count
        if ($sameTypeCount -le 1) {
            Show-Message '工作流必须保留一个开始节点和一个结束节点。' '删除节点' ([Windows.Forms.MessageBoxIcon]::Information)
            return
        }
    }
    $id = $script:SelectedNode.Id
    $script:CurrentWorkflow.Nodes = @($script:CurrentWorkflow.Nodes | Where-Object { $_.Id -ne $id })
    $script:CurrentWorkflow.Edges = @($script:CurrentWorkflow.Edges | Where-Object { $_.From -ne $id -and $_.To -ne $id })
    $script:CurrentWorkflow.UpdatedAt = (Get-Date).ToString('o')
    $script:SelectedNode = $null
    $script:SelectedEdge = $null
    $script:Canvas.Invalidate()
}

function Remove-SelectedCanvasItem {
    if ($null -ne $script:SelectedEdge -and $null -ne $script:CurrentWorkflow) {
        $from = [string]$script:SelectedEdge.From; $to = [string]$script:SelectedEdge.To
        $script:CurrentWorkflow.Edges = @($script:CurrentWorkflow.Edges | Where-Object { -not ([string]$_.From -eq $from -and [string]$_.To -eq $to) })
        $script:CurrentWorkflow.UpdatedAt = (Get-Date).ToString('o')
        $script:SelectedEdge = $null
        $script:Canvas.Invalidate()
        return
    }
    Remove-SelectedNode
}

function Invoke-CanvasDeleteShortcut {
    param([Windows.Forms.KeyEventArgs]$EventArgs)
    if ($null -eq $EventArgs -or $EventArgs.Handled -or $EventArgs.KeyCode -ne [Windows.Forms.Keys]::Delete) { return }
    if ($null -eq $script:SelectedNode -and $null -eq $script:SelectedEdge) { return }
    Remove-SelectedCanvasItem
    $EventArgs.Handled = $true
    $EventArgs.SuppressKeyPress = $true
}

function Copy-SelectedCanvasNode {
    if ($null -eq $script:SelectedNode -or $null -eq $script:CurrentWorkflow) { return $false }
    if ([string]$script:SelectedNode.Type -in @('Start','End')) {
        Show-Message '开始和结束节点不能复制。' '复制节点' ([Windows.Forms.MessageBoxIcon]::Information)
        return $false
    }
    $script:CopiedCanvasNodeJson = $script:SelectedNode | ConvertTo-Json -Depth 30 -Compress
    if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '已复制节点：' + [string]$script:SelectedNode.Name }
    return $true
}

function Paste-CopiedCanvasNode {
    param($Point = $null)
    if ($null -eq $script:CurrentWorkflow -or [string]::IsNullOrWhiteSpace($script:CopiedCanvasNodeJson)) { return $null }
    try { $source = $script:CopiedCanvasNodeJson | ConvertFrom-Json } catch { return $null }
    if ([string]$source.Type -in @('Start','End')) { return $null }
    $x = if ($null -ne $Point) { ConvertTo-CanvasInt $Point.X } else { (ConvertTo-CanvasInt $source.X) + 36 }
    $y = if ($null -ne $Point) { ConvertTo-CanvasInt $Point.Y } else { (ConvertTo-CanvasInt $source.Y) + 36 }
    $copy = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Type = [string]$source.Type
        Name = [string]$source.Name + ' - 副本'
        X = [Math]::Max(10, $x)
        Y = [Math]::Max(10, $y)
        Width = ConvertTo-CanvasInt $source.Width
        Height = ConvertTo-CanvasInt $source.Height
        Config = if ($null -eq $source.Config) { [pscustomobject]@{} } else { ($source.Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json) }
    }
    $script:CurrentWorkflow.Nodes = @($script:CurrentWorkflow.Nodes) + $copy
    $script:CurrentWorkflow.UpdatedAt = (Get-Date).ToString('o')
    $script:SelectedNode = $copy
    $script:SelectedEdge = $null
    Update-CanvasExtent
    $script:Canvas.Invalidate()
    if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '已粘贴节点：' + [string]$copy.Name }
    return $copy
}

function Invoke-CanvasClipboardShortcut {
    param([Windows.Forms.KeyEventArgs]$EventArgs)
    if ($null -eq $EventArgs -or $EventArgs.Handled -or -not $EventArgs.Control) { return }
    if ($EventArgs.KeyCode -eq [Windows.Forms.Keys]::C) {
        if (Copy-SelectedCanvasNode) { $EventArgs.Handled=$true; $EventArgs.SuppressKeyPress=$true }
    } elseif ($EventArgs.KeyCode -eq [Windows.Forms.Keys]::V) {
        if ($null -ne (Paste-CopiedCanvasNode)) { $EventArgs.Handled=$true; $EventArgs.SuppressKeyPress=$true }
    }
}

function Get-DefaultCanvasExtent {
    $screen = $null
    try {
        if ($null -ne $script:MainForm -and -not $script:MainForm.IsDisposed) { $screen = [Windows.Forms.Screen]::FromControl($script:MainForm) }
        if ($null -eq $screen) { $screen = [Windows.Forms.Screen]::PrimaryScreen }
    } catch { $screen = $null }
    $screenWidth = if ($null -ne $screen) { [int]$screen.Bounds.Width } else { 1920 }
    $screenHeight = if ($null -ne $screen) { [int]$screen.Bounds.Height } else { 1080 }
    return New-Object Drawing.Size([Math]::Max(1600, $screenWidth * 2), [Math]::Max(900, $screenHeight * 2))
}

function Update-CanvasExtent {
    if ($null -eq $script:Canvas -or $script:Canvas.IsDisposed) { return }
    $extent = Get-DefaultCanvasExtent
    $requiredWidth = [int]$extent.Width
    $requiredHeight = [int]$extent.Height
    if ($null -ne $script:CurrentWorkflow) {
        foreach ($node in @($script:CurrentWorkflow.Nodes)) {
            $requiredWidth = [Math]::Max($requiredWidth, (ConvertTo-CanvasInt $node.X) + (ConvertTo-CanvasInt $node.Width) + 360)
            $requiredHeight = [Math]::Max($requiredHeight, (ConvertTo-CanvasInt $node.Y) + (ConvertTo-CanvasInt $node.Height) + 280)
        }
    }
    if ($script:Canvas.AutoScrollMinSize.Width -ne $requiredWidth -or $script:Canvas.AutoScrollMinSize.Height -ne $requiredHeight) {
        $script:Canvas.AutoScrollMinSize = New-Object Drawing.Size($requiredWidth, $requiredHeight)
    }
}

function Layout-WorkflowTree {
    if ($null -eq $script:CurrentWorkflow) { return }
    $nodes = @($script:CurrentWorkflow.Nodes)
    $start = @($nodes | Where-Object Type -eq 'Start' | Select-Object -First 1)
    if ($start.Count -eq 0) { return }
    $levels = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($start[0].Id, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $id = [string]$item[0]; $level = [int]$item[1]
        if ($levels.ContainsKey($id)) { continue }
        $levels[$id] = $level
        foreach ($edge in @($script:CurrentWorkflow.Edges | Where-Object From -eq $id)) { $queue.Enqueue(@([string]$edge.To, $level + 1)) }
    }
    $unplaced = @($nodes | Where-Object { -not $levels.ContainsKey([string]$_.Id) })
    foreach ($node in $unplaced) { $levels[[string]$node.Id] = 0 }
    $groups = @{}
    foreach ($node in $nodes) {
        $level = [int]$levels[[string]$node.Id]
        if (-not $groups.ContainsKey($level)) { $groups[$level] = New-Object System.Collections.ArrayList }
        [void]$groups[$level].Add($node)
    }
    foreach ($level in ($groups.Keys | Sort-Object)) {
        $items = @($groups[$level])
        for ($i = 0; $i -lt $items.Count; $i++) {
            $items[$i].X = 40 + ([int]$level * 250)
            $items[$i].Y = 50 + ($i * 125)
        }
    }
    Update-CanvasExtent
    $script:Canvas.Invalidate()
}

function Paint-WorkflowCanvas {
    param($Sender, $EventArgs)
    $canvas = @($Sender) | Where-Object { $_ -is [Windows.Forms.Control] } | Select-Object -Last 1
    $paintEvent = @($EventArgs) | Where-Object { $_ -is [Windows.Forms.PaintEventArgs] } | Select-Object -Last 1
    if ($null -eq $canvas -or $null -eq $paintEvent) { return }
    $g = $paintEvent.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::FromArgb(248, 250, 252))
    $offset = $canvas.AutoScrollPosition
    $offsetX = ConvertTo-CanvasInt $offset.X; $offsetY = ConvertTo-CanvasInt $offset.Y
    $canvasWidth = ConvertTo-CanvasInt $canvas.ClientSize.Width; $canvasHeight = ConvertTo-CanvasInt $canvas.ClientSize.Height
    $gridWidth = [Math]::Max($canvasWidth, [int]$canvas.AutoScrollMinSize.Width)
    $gridHeight = [Math]::Max($canvasHeight, [int]$canvas.AutoScrollMinSize.Height)
    $visibleLeft = [Math]::Max(0, -$offsetX)
    $visibleTop = [Math]::Max(0, -$offsetY)
    $visibleRight = [Math]::Min($gridWidth, $visibleLeft + $canvasWidth + 24)
    $visibleBottom = [Math]::Min($gridHeight, $visibleTop + $canvasHeight + 24)
    $gridStartX = [int]([Math]::Floor($visibleLeft / 24.0) * 24)
    $gridStartY = [int]([Math]::Floor($visibleTop / 24.0) * 24)
    $g.TranslateTransform($offsetX, $offsetY)
    $minorGridPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(232, 236, 241), 1)
    $majorGridPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(218, 225, 234), 1)
    for ($x = $gridStartX; $x -le $visibleRight; $x += 24) {
        $pen = if (($x % 120) -eq 0) { $majorGridPen } else { $minorGridPen }
        $g.DrawLine($pen, $x, $visibleTop, $x, $visibleBottom)
    }
    for ($y = $gridStartY; $y -le $visibleBottom; $y += 24) {
        $pen = if (($y % 120) -eq 0) { $majorGridPen } else { $minorGridPen }
        $g.DrawLine($pen, $visibleLeft, $y, $visibleRight, $y)
    }
    $minorGridPen.Dispose(); $majorGridPen.Dispose()
    if ($null -eq $script:CurrentWorkflow) { return }
    foreach ($layoutNode in @($script:CurrentWorkflow.Nodes)) { [void](Sync-InlineVariableNodeLayout $layoutNode) }
    $edgePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(100, 116, 139), 2)
    $edgePen.EndCap = [Drawing.Drawing2D.LineCap]::ArrowAnchor
    $selectedEdgePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(234, 88, 12), 3)
    $selectedEdgePen.EndCap = [Drawing.Drawing2D.LineCap]::ArrowAnchor
    $edgeLabelFont = New-UiFont 8 ([Drawing.FontStyle]::Bold)
    foreach ($edge in @($script:CurrentWorkflow.Edges)) {
        $from = Get-NodeById ([string]$edge.From); $to = Get-NodeById ([string]$edge.To)
        if ($null -eq $from -or $null -eq $to) { continue }
        $fromX = ConvertTo-CanvasInt $from.X; $fromY = ConvertTo-CanvasInt $from.Y
        $fromWidth = ConvertTo-CanvasInt $from.Width; $fromHeight = ConvertTo-CanvasInt $from.Height
        $toX = ConvertTo-CanvasInt $to.X; $toY = ConvertTo-CanvasInt $to.Y; $toHeight = ConvertTo-CanvasInt $to.Height
        $x1 = $fromX + $fromWidth; $y1 = $fromY + [int]($fromHeight / 2)
        $x2 = $toX; $y2 = $toY + [int]($toHeight / 2)
        $isSelected = $null -ne $script:SelectedEdge -and [string]$script:SelectedEdge.From -eq [string]$edge.From -and [string]$script:SelectedEdge.To -eq [string]$edge.To
        $drawPen = $edgePen
        if ($isSelected) { $drawPen = $selectedEdgePen }
        $g.DrawLine($drawPen, $x1, $y1, $x2, $y2)
        $branch = [string](Get-UiConfigValue $edge 'Branch' '')
        if (-not [string]::IsNullOrWhiteSpace($branch)) {
            $label = switch ($branch) { 'True' { '是' }; 'False' { '否' }; 'Body' { '循环' }; 'Done' { '完成' }; default { $branch } }
            $labelColor = switch ($branch) { 'True' { [Drawing.Color]::FromArgb(21, 128, 61) }; 'False' { [Drawing.Color]::FromArgb(185, 28, 28) }; 'Body' { [Drawing.Color]::FromArgb(67, 56, 202) }; default { [Drawing.Color]::FromArgb(71, 85, 105) } }
            $labelBrush = New-Object Drawing.SolidBrush($labelColor)
            $labelBack = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(245, 255, 255, 255))
            $labelY = if ($branch -in @('False','Done')) { $y1 + 7 } else { $y1 - 23 }
            $labelSize = $g.MeasureString($label, $edgeLabelFont)
            $g.FillRectangle($labelBack, ($x1 + 8), $labelY, ($labelSize.Width + 8), ($labelSize.Height + 2))
            $g.DrawString($label, $edgeLabelFont, $labelBrush, ($x1 + 12), ($labelY + 1))
            $labelBrush.Dispose(); $labelBack.Dispose()
        }
    }
    if ($null -ne $script:ConnectingFrom -and $null -ne $script:ConnectPoint) {
        $connectFromX = ConvertTo-CanvasInt $script:ConnectingFrom.X
        $connectFromY = ConvertTo-CanvasInt $script:ConnectingFrom.Y
        $connectFromWidth = ConvertTo-CanvasInt $script:ConnectingFrom.Width
        $connectFromHeight = ConvertTo-CanvasInt $script:ConnectingFrom.Height
        $x1 = $connectFromX + $connectFromWidth
        $y1 = $connectFromY + [int]($connectFromHeight / 2)
        $connectX = ConvertTo-CanvasInt $script:ConnectPoint.X; $connectY = ConvertTo-CanvasInt $script:ConnectPoint.Y
        $g.DrawLine($edgePen, $x1, $y1, $connectX, $connectY)
    }
    $edgePen.Dispose()
    $selectedEdgePen.Dispose()
    $edgeLabelFont.Dispose()
    $font = New-UiFont 9
    $typeFont = New-UiFont 8
    $inlineFont = New-UiFont 8.5
    $inlineValueFont = New-UiFont 8.5 ([Drawing.FontStyle]::Bold)
    foreach ($node in @($script:CurrentWorkflow.Nodes)) {
        $inlineRows = @(Get-NodeInlineVariableRows $node)
        $nodeX = ConvertTo-CanvasInt $node.X; $nodeY = ConvertTo-CanvasInt $node.Y
        $nodeWidth = ConvertTo-CanvasInt $node.Width; $nodeHeight = ConvertTo-CanvasInt $node.Height
        $color = Get-NodeColor $node.Type
        $fill = New-Object Drawing.SolidBrush($color)
        $body = New-Object Drawing.SolidBrush([Drawing.Color]::White)
        $border = New-Object Drawing.Pen($color, 2)
        $rect = New-Object Drawing.Rectangle($nodeX, $nodeY, $nodeWidth, $nodeHeight)
        $g.FillRectangle($body, $rect)
        $g.FillRectangle($fill, $nodeX, $nodeY, $nodeWidth, 7)
        $g.DrawRectangle($border, $rect)
        if ($null -ne $script:SelectedNode -and $script:SelectedNode.Id -eq $node.Id) {
            $selectedPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(15, 23, 42), 2)
            $selectedX = Get-CanvasDelta $nodeX 4; $selectedY = Get-CanvasDelta $nodeY 4
            $selectedRect = New-Object Drawing.Rectangle($selectedX, $selectedY, ($nodeWidth + 8), ($nodeHeight + 8))
            $g.DrawRectangle($selectedPen, $selectedRect)
            $selectedPen.Dispose()
        }
        $g.DrawString((Get-NodeTypeLabel $node.Type), $typeFont, [Drawing.Brushes]::DimGray, ($nodeX + 12), ($nodeY + 17))
        $g.DrawString([string]$node.Name, $font, [Drawing.Brushes]::Black, ($nodeX + 12), ($nodeY + 37))
        if ($inlineRows.Count -gt 0) {
            $dividerPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(226, 232, 240), 1)
            $g.DrawLine($dividerPen, ($nodeX + 10), ($nodeY + 63), ($nodeX + $nodeWidth - 10), ($nodeY + 63))
            $dividerPen.Dispose()
            for ($rowIndex = 0; $rowIndex -lt $inlineRows.Count; $rowIndex++) {
                $row = $inlineRows[$rowIndex]
                $rowY = $nodeY + 68 + ($rowIndex * 24)
                $label = [string](Get-UiConfigValue $row 'Label' '')
                if ([string]::IsNullOrWhiteSpace($label)) { $label = [string](Get-UiConfigValue $row 'Name' '') }
                $labelRect = New-Object Drawing.RectangleF(($nodeX + 12), ($rowY + 3), ([single]($nodeWidth * 0.41)), 19)
                $labelFormat = New-Object Drawing.StringFormat; $labelFormat.Trimming = [Drawing.StringTrimming]::EllipsisCharacter; $labelFormat.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
                $g.DrawString($label, $inlineFont, [Drawing.Brushes]::DimGray, $labelRect, $labelFormat)
                $labelFormat.Dispose()
                $valueX = $nodeX + [int]($nodeWidth * 0.45); $valueWidth = [Math]::Max(60, [int]($nodeWidth * 0.50) - 8)
                $state = Get-InlineVariableBooleanState (Get-UiConfigValue $row 'Value' '') ([string](Get-UiConfigValue $row 'ValueType' ''))
                if ($state.IsBoolean) {
                    $pillColor = if ($state.Value) { [Drawing.Color]::FromArgb(220, 252, 231) } else { [Drawing.Color]::FromArgb(241, 245, 249) }
                    $pillTextColor = if ($state.Value) { [Drawing.Color]::FromArgb(21, 128, 61) } else { [Drawing.Color]::FromArgb(100, 116, 139) }
                    $pillBrush = New-Object Drawing.SolidBrush($pillColor); $pillTextBrush = New-Object Drawing.SolidBrush($pillTextColor)
                    $g.FillRectangle($pillBrush, $valueX, ($rowY + 2), $valueWidth, 20)
                    $pillFormat = New-Object Drawing.StringFormat; $pillFormat.Alignment = [Drawing.StringAlignment]::Center; $pillFormat.LineAlignment = [Drawing.StringAlignment]::Center
                    $g.DrawString([string]$state.Text, $inlineValueFont, $pillTextBrush, (New-Object Drawing.RectangleF($valueX, ($rowY + 1), $valueWidth, 21)), $pillFormat)
                    $pillFormat.Dispose(); $pillBrush.Dispose(); $pillTextBrush.Dispose()
                } else {
                    $valueBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(248, 250, 252))
                    $g.FillRectangle($valueBrush, $valueX, ($rowY + 2), $valueWidth, 20); $valueBrush.Dispose()
                    $valueRect = New-Object Drawing.RectangleF(($valueX + 6), ($rowY + 3), ([single]($valueWidth - 12)), 18)
                    $valueFormat = New-Object Drawing.StringFormat; $valueFormat.Trimming = [Drawing.StringTrimming]::EllipsisCharacter; $valueFormat.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
                    $g.DrawString([string]$state.Text, $inlineFont, [Drawing.Brushes]::SlateGray, $valueRect, $valueFormat); $valueFormat.Dispose()
                }
            }
        }
        $portBrush = New-Object Drawing.SolidBrush($color)
        $portX = Get-CanvasDelta ($nodeX + $nodeWidth) 13
        $portY = Get-CanvasDelta ($nodeY + [int]($nodeHeight / 2)) 6
        $g.FillEllipse($portBrush, $portX, $portY, 12, 12)
        $portBrush.Dispose(); $fill.Dispose(); $body.Dispose(); $border.Dispose()
    }
    $font.Dispose(); $typeFont.Dispose(); $inlineFont.Dispose(); $inlineValueFont.Dispose()
}

function Get-UiConfigValue {
    param($Config, [string]$Name, $Default = $null)
    if ($null -eq $Config) { return $Default }
    try {
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains($Name)) { return $Config[$Name] }
            foreach ($key in $Config.Keys) { if ([string]$key -ieq $Name) { return $Config[$key] } }
            return $Default
        }
        $properties = ([System.Management.Automation.PSObject]::AsPSObject($Config)).PSObject.Properties
        $property = $properties[$Name]
        if ($null -eq $property) { $property = @($properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1) | Select-Object -First 1 }
        if ($null -eq $property) { return $Default }
        return $property.Value
    } catch { return $Default }
}

function Test-UiConfigValue {
    param($Config, [string]$Name)
    if ($null -eq $Config) { return $false }
    try {
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains($Name)) { return $true }
            foreach ($key in $Config.Keys) { if ([string]$key -ieq $Name) { return $true } }
            return $false
        }
        $properties = ([System.Management.Automation.PSObject]::AsPSObject($Config)).PSObject.Properties
        if ($null -ne $properties[$Name]) { return $true }
        return @($properties | Where-Object { $_.Name -ieq $Name }).Count -gt 0
    } catch { return $false }
}

function Set-UiConfigValue {
    param($Config, [string]$Name, $Value)
    if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($Name)) { return $false }
    try {
        if ($Config -is [System.Collections.IDictionary]) {
            $existingKey = @($Config.Keys | Where-Object { [string]$_ -ieq $Name } | Select-Object -First 1)
            if ($existingKey.Count -gt 0) { $Config[$existingKey[0]] = $Value } else { $Config[$Name] = $Value }
            return $true
        }
        $property = @(([System.Management.Automation.PSObject]::AsPSObject($Config)).PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1)
        if ($property.Count -gt 0) { $property[0].Value = $Value; return $true }
        $Config | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
        return $true
    } catch { return $false }
}

function Get-NodeInlineVariableRows {
    param($Node)
    if ($null -eq $Node -or [string]$Node.Type -ne 'EnvWrite') { return @() }
    if (-not [bool](Get-UiConfigValue $Node.Config 'InlineEdit' $false)) { return @() }
    $rawItems = @(Get-UiConfigValue $Node.Config 'Items' @())
    if ($rawItems.Count -gt 0 -and @($rawItems | Where-Object { -not (Test-UiConfigValue $_ 'Name') }).Count -eq 0) { return $rawItems }
    $normalizedItems = @(Get-UiEnvironmentItems $Node.Config)
    [void](Set-UiConfigValue $Node.Config 'Items' $normalizedItems)
    return $normalizedItems
}

function Get-InlineVariableBooleanState {
    param($Value, [string]$ValueType = '')
    $text = if ($null -eq $Value) { '' } else { ([string]$Value).Trim().ToLowerInvariant() }
    if ($ValueType -eq 'Boolean' -or $text -in @('true','false','yes','no','on','off','1','0','是','否')) {
        $isTrue = $text -in @('true','yes','on','1','是')
        return [pscustomobject]@{ IsBoolean = $true; Value = $isTrue; Text = if ($isTrue) { '是' } else { '否' } }
    }
    return [pscustomobject]@{ IsBoolean = $false; Value = $Value; Text = [string]$Value }
}

function Sync-InlineVariableNodeLayout {
    param($Node)
    $rows = @(Get-NodeInlineVariableRows $Node)
    if ($rows.Count -eq 0) { return $rows }
    $Node.Width = [Math]::Max(280, (ConvertTo-CanvasInt $Node.Width))
    $Node.Height = [Math]::Max((88 + ($rows.Count * 24)), (ConvertTo-CanvasInt $Node.Height))
    return $rows
}

function Get-CanvasInlineVariableHit {
    param([int]$X, [int]$Y)
    if ($null -eq $script:CurrentWorkflow) { return $null }
    $nodes = @($script:CurrentWorkflow.Nodes)
    for ($nodeIndex = $nodes.Count - 1; $nodeIndex -ge 0; $nodeIndex--) {
        $node = $nodes[$nodeIndex]
        $rows = @(Sync-InlineVariableNodeLayout $node)
        if ($rows.Count -eq 0) { continue }
        $nodeX = ConvertTo-CanvasInt $node.X; $nodeY = ConvertTo-CanvasInt $node.Y
        $nodeWidth = ConvertTo-CanvasInt $node.Width; $nodeHeight = ConvertTo-CanvasInt $node.Height
        $nodeRight = [int]$nodeX + [int]$nodeWidth
        $nodeBottom = [int]$nodeY + [int]$nodeHeight
        if ([int]$X -lt [int]$nodeX -or [int]$X -gt [int]$nodeRight -or [int]$Y -lt [int]$nodeY -or [int]$Y -gt [int]$nodeBottom) { continue }
        $rowTop = [int]$nodeY + 68
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $top = $rowTop + ($index * 24)
            $rowBottom = [int]$top + 24
            $valueLeft = [int]$nodeX + [int]([int]$nodeWidth * 0.45)
            if ([int]$Y -ge [int]$top -and [int]$Y -lt [int]$rowBottom -and [int]$X -ge [int]$valueLeft) {
                $valueWidth = [int]([int]$nodeWidth * 0.52)
                return [pscustomobject]@{ Node = $node; Row = $rows[$index]; Index = $index; ValueRectangle = (New-Object Drawing.Rectangle([int]$valueLeft, [int]$top, [int]$valueWidth, 24)) }
            }
        }
    }
    return $null
}

function Show-InlineVariableValueEditor {
    param($Hit)
    if ($null -eq $Hit -or $null -eq $Hit.Row) { return $false }
    $row = $Hit.Row
    $form = New-Object Windows.Forms.Form
    Set-WorkflowFormScaling $form
    $form.Text = '编辑变量值 - ' + [string](Get-UiConfigValue $row 'Name' '')
    $form.StartPosition = 'CenterParent'; $form.FormBorderStyle = 'FixedDialog'; $form.MinimizeBox = $false; $form.MaximizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(480, 190); Set-WorkflowWindowIcon $form
    Add-UiLabel $form ([string](Get-UiConfigValue $row 'Label' (Get-UiConfigValue $row 'Name' '变量值'))) 24 22 420 24 | Out-Null
    $box = New-Object Windows.Forms.TextBox; $box.Location = New-Object Drawing.Point(24, 52); $box.Size = New-Object Drawing.Size(432, 64); $box.Multiline = $true; $box.ScrollBars = 'Vertical'; $box.Text = [string](Get-UiConfigValue $row 'Value' ''); $form.Controls.Add($box)
    $cancel = Add-UiButton $form '取消' 244 132 96 34; $cancel.DialogResult = 'Cancel'; $form.CancelButton = $cancel
    $save = Add-UiButton $form '保存' 360 132 96 34 'Primary'
    $save.Add_Click({ $row.Value = $box.Text; if ([string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $row 'ValueType' ''))) { $row.ValueType = 'String' }; $form.DialogResult = 'OK'; $form.Close() })
    Apply-UiTheme $form
    try{return ($form.ShowDialog($script:MainForm) -eq [Windows.Forms.DialogResult]::OK)}
    finally{if($null-ne$form-and-not$form.IsDisposed){$form.Dispose()}}
}

function Invoke-CanvasInlineVariableEdit {
    param($Hit)
    if ($null -eq $Hit -or $null -eq $Hit.Row) { return $false }
    $row = $Hit.Row
    $state = Get-InlineVariableBooleanState (Get-UiConfigValue $row 'Value' '') ([string](Get-UiConfigValue $row 'ValueType' ''))
    if ($state.IsBoolean) {
        $row.Value = if ($state.Value) { 'false' } else { 'true' }
        $row.ValueType = 'Boolean'
    } else {
        if (-not (Show-InlineVariableValueEditor $Hit)) { return $false }
    }
    if ($null -ne $script:CurrentWorkflow) { $script:CurrentWorkflow.UpdatedAt = (Get-Date).ToString('o') }
    Save-Workflows
    Update-CanvasExtent
    if ($null -ne $script:Canvas -and -not $script:Canvas.IsDisposed) { $script:Canvas.Invalidate() }
    return $true
}

function ConvertTo-UiEnvironmentRows {
    param($ItemsValue, [switch]$Read)
    $rows = New-Object System.Collections.ArrayList
    $rightName = if ($Read) { 'Variable' } else { 'Value' }
    foreach ($item in @($ItemsValue)) {
        if ($null -eq $item) { continue }
        if (Test-UiConfigValue $item 'Name') {
            $name = [string](Get-UiConfigValue $item 'Name' '')
            $right = Get-UiConfigValue $item $rightName ''
            if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = $name; Variable = [string]$right }) }
            else { [void]$rows.Add([pscustomobject]@{ Name = $name; Label = [string](Get-UiConfigValue $item 'Label' ''); Value = [string]$right; ValueType = [string](Get-UiConfigValue $item 'ValueType' '') }) }
            continue
        }
        if (Test-UiConfigValue $item 'Key') {
            $name = [string](Get-UiConfigValue $item 'Key' '')
            $right = Get-UiConfigValue $item 'Value' ''
            if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = $name; Variable = [string]$right }) }
            else { [void]$rows.Add([pscustomobject]@{ Name = $name; Value = [string]$right }) }
            continue
        }
        if (Test-UiConfigValue $item $rightName) {
            $right = Get-UiConfigValue $item $rightName ''
            if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = ''; Variable = [string]$right }) }
            else { [void]$rows.Add([pscustomobject]@{ Name = ''; Value = [string]$right }) }
            continue
        }
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($key in @($item.Keys)) {
                if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = [string]$key; Variable = [string]$item[$key] }) }
                else { [void]$rows.Add([pscustomobject]@{ Name = [string]$key; Value = [string]$item[$key] }) }
            }
            continue
        }
        $mapProperties = @($item.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
        if ($mapProperties.Count -gt 0) {
            foreach ($property in $mapProperties) {
                if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = [string]$property.Name; Variable = [string]$property.Value }) }
                else { [void]$rows.Add([pscustomobject]@{ Name = [string]$property.Name; Value = [string]$property.Value }) }
            }
            continue
        }
        if ($Read) { [void]$rows.Add([pscustomobject]@{ Name = [string]$item; Variable = '' }) }
        else { [void]$rows.Add([pscustomobject]@{ Name = [string]$item; Value = '' }) }
    }
    return @($rows)
}

function Get-UiEnvironmentItems {
    param($Config, [switch]$Read)
    $itemsValue = Get-UiConfigValue $Config 'Items' $null
    if ($null -ne $itemsValue -and @($itemsValue).Count -gt 0) { return @(ConvertTo-UiEnvironmentRows $itemsValue -Read:$Read) }
    $mode = [string](Get-UiConfigValue $Config 'Mode' 'Single')
    $items = @()
    if ($mode -eq 'Json') {
        try { $object = [string](Get-UiConfigValue $Config 'Json' '') | ConvertFrom-Json } catch { return @() }
        foreach ($property in @($object.PSObject.Properties)) {
            if ($Read) { $items += [pscustomobject]@{ Name = [string]$property.Name; Variable = [string]$property.Value } }
            else { $items += [pscustomobject]@{ Name = [string]$property.Name; Value = [string]$property.Value } }
        }
        return $items
    }
    $name = [string](Get-UiConfigValue $Config 'Name' '')
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        if ($Read) { $items += [pscustomobject]@{ Name = $name; Variable = [string](Get-UiConfigValue $Config 'Variable' '') } }
        else { $items += [pscustomobject]@{ Name = $name; Value = [string](Get-UiConfigValue $Config 'Value' '') } }
    }
    return $items
}

function New-EnvironmentGrid {
    param($Parent, [int]$Y, [string]$LeftHeader, [string]$RightHeader, $Items, [switch]$IncludeLabel)
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object Drawing.Point(24, $Y)
    $grid.Size = New-Object Drawing.Size(566, 270)
    $grid.Anchor = 'Top,Left,Right'
    $grid.BackgroundColor = [Drawing.Color]::White
    $grid.BorderStyle = 'Fixed3D'
    $grid.GridColor = [Drawing.Color]::FromArgb(226,232,240)
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $true
    $grid.AllowUserToDeleteRows = $true
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.EditMode = 'EditOnEnter'
    $grid.AutoSizeRowsMode = 'None'
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.ColumnHeadersHeight = 32
    $grid.RowTemplate.Height = 32
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.Font = New-UiFont 9
    if ($IncludeLabel) {
        [void]$grid.Columns.Add('DisplayLabel', '显示名')
        [void]$grid.Columns.Add('LeftValue', $LeftHeader)
        [void]$grid.Columns.Add('RightValue', $RightHeader)
        $grid.Columns['DisplayLabel'].FillWeight = 28
        $grid.Columns['LeftValue'].FillWeight = 30
        $grid.Columns['RightValue'].FillWeight = 42
    } else {
        [void]$grid.Columns.Add('LeftValue', $LeftHeader)
        [void]$grid.Columns.Add('RightValue', $RightHeader)
        $grid.Columns['LeftValue'].FillWeight = 38
        $grid.Columns['RightValue'].FillWeight = 62
    }
    $Parent.Controls.Add($grid)
    foreach ($item in @($Items)) {
        $rowIndex = $grid.Rows.Add()
        $row = $grid.Rows[$rowIndex]
        $row.Tag = $item
        if ($IncludeLabel) { $row.Cells['DisplayLabel'].Value = [string](Get-UiConfigValue $item 'Label' '') }
        $row.Cells['LeftValue'].Value = [string](Get-UiConfigValue $item 'Name' '')
        $rightValue = if (Test-UiConfigValue $item 'Variable') { Get-UiConfigValue $item 'Variable' '' } else { Get-UiConfigValue $item 'Value' '' }
        $row.Cells['RightValue'].Value = [string]$rightValue
    }
    return $grid
}

function Get-EnvironmentGridItems {
    param($Grid, [switch]$Read, [switch]$IncludeLabel)
    $items = New-Object System.Collections.ArrayList
    foreach ($row in @($Grid.Rows)) {
        if ($row.IsNewRow) { continue }
        $name = [string]$row.Cells['LeftValue'].Value
        $right = [string]$row.Cells['RightValue'].Value
        if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($right)) { continue }
        if ([string]::IsNullOrWhiteSpace($name)) { throw '每一行都必须填写变量名。' }
        if ($Read -and [string]::IsNullOrWhiteSpace($right)) { throw '变量读取表格的每一行都必须填写任务变量名。' }
        if ($Read) { [void]$items.Add([pscustomobject]@{ Name = $name.Trim(); Variable = $right.Trim() }) }
        else {
            $label = if ($IncludeLabel) { [string]$row.Cells['DisplayLabel'].Value } else { '' }
            $valueType = [string](Get-UiConfigValue $row.Tag 'ValueType' '')
            if ([string]::IsNullOrWhiteSpace($valueType) -and $right.Trim().ToLowerInvariant() -in @('true','false','yes','no','on','off','是','否')) { $valueType = 'Boolean' }
            [void]$items.Add([pscustomobject]@{ Name = $name.Trim(); Label = $label.Trim(); Value = $right; ValueType = $valueType })
        }
    }
    return @($items)
}

function Show-NodeEditor {
    param($Node)
    $form = New-Object System.Windows.Forms.Form
    Set-WorkflowFormScaling $form
    $form.Text = '节点配置 - ' + (Get-NodeTypeLabel $Node.Type)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(620, 640)
    $form.Font = New-UiFont 9
    Set-WorkflowWindowIcon $form
    $form.Add_HandleCreated({ param($sender, $eventArgs) Set-WorkflowWindowIcon $sender })
    Add-UiLabel $form '节点名称' 24 24 110 24 | Out-Null
    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Location = New-Object System.Drawing.Point(142, 21); $nameBox.Size = New-Object System.Drawing.Size(448, 28); $nameBox.Text = [string]$Node.Name; $form.Controls.Add($nameBox)
    Add-UiLabel $form '节点类型' 24 66 110 24 | Out-Null
    $typeBox = New-Object System.Windows.Forms.TextBox
    $typeBox.Location = New-Object System.Drawing.Point(142, 63); $typeBox.Size = New-Object System.Drawing.Size(448, 28); $typeBox.ReadOnly = $true; $typeBox.Text = Get-NodeTypeLabel $Node.Type; $form.Controls.Add($typeBox)

    $methodBox = $null; $urlBox = $null; $headersBox = $null; $bodyBox = $null; $responseBox = $null; $expectedBox = $null
    $envGrid = $null; $envInlineEditBox = $null
    $commandBox = $null; $workingDirectoryBox = $null; $timeoutBox = $null; $outputVarBox = $null; $failOnErrorBox = $null
    $pythonModeBox = $null; $pythonScriptBox = $null; $pythonWorkingDirectoryBox = $null; $pythonArgumentsBox = $null; $pythonTimeoutBox = $null; $pythonOutputVarBox = $null; $pythonFailOnErrorBox = $null
    $codexWorkingDirectoryBox = $null; $codexSessionIdBox = $null; $codexRequestBox = $null; $codexLiveDataBox = $null; $codexTimeoutBox = $null; $codexOutputVarBox = $null; $codexFailOnErrorBox = $null
    $titleBox = $null; $messageBox = $null; $balloonActionBox = $null; $balloonTargetBox = $null
    $variableNameBox = $null; $variableTypeBox = $null; $variableValueBox = $null
    $ifLeftBox = $null; $ifOperatorBox = $null; $ifRightBox = $null; $ifOutputBox = $null
    $loopItemsBox = $null; $loopItemVariableBox = $null; $loopIndexVariableBox = $null; $loopResultVariableBox = $null
    $delaySecondsBox = $null
    switch ($Node.Type) {
        'HttpRequest' {
            Add-UiLabel $form '请求方法' 24 110 110 24 | Out-Null
            $methodBox = New-Object System.Windows.Forms.ComboBox
            $methodBox.Location = New-Object System.Drawing.Point(142, 107); $methodBox.Size = New-Object System.Drawing.Size(120, 28); $methodBox.DropDownStyle = 'DropDownList'
            foreach ($method in @('GET','POST','PUT','PATCH','DELETE')) { [void]$methodBox.Items.Add($method) }
            $methodValue = [string]$Node.Config.Method; if ([string]::IsNullOrWhiteSpace($methodValue)) { $methodValue = 'GET' }; $methodBox.SelectedItem = $methodValue
            $form.Controls.Add($methodBox)
            Add-UiLabel $form 'URL' 24 150 110 24 | Out-Null
            $urlBox = New-Object System.Windows.Forms.TextBox
            $urlBox.Location = New-Object System.Drawing.Point(142, 147); $urlBox.Size = New-Object System.Drawing.Size(448, 28); $urlBox.Text = [string]$Node.Config.Url; $form.Controls.Add($urlBox)
            Add-UiLabel $form '请求头 JSON' 24 191 110 24 | Out-Null
            $headersBox = New-Object System.Windows.Forms.TextBox
            $headersBox.Location = New-Object System.Drawing.Point(142, 188); $headersBox.Size = New-Object System.Drawing.Size(448, 60); $headersBox.Multiline = $true; $headersBox.ScrollBars = 'Vertical'; $headersBox.Text = [string]$Node.Config.Headers; $form.Controls.Add($headersBox)
            Add-UiLabel $form '请求体模板' 24 263 110 24 | Out-Null
            $bodyBox = New-Object System.Windows.Forms.TextBox
            $bodyBox.Location = New-Object System.Drawing.Point(142, 260); $bodyBox.Size = New-Object System.Drawing.Size(448, 120); $bodyBox.Multiline = $true; $bodyBox.ScrollBars = 'Vertical'; $bodyBox.Text = [string]$Node.Config.Body; $form.Controls.Add($bodyBox)
            Add-UiLabel $form '响应变量' 24 397 110 24 | Out-Null
            $responseBox = New-Object System.Windows.Forms.TextBox
            $responseBox.Location = New-Object System.Drawing.Point(142, 394); $responseBox.Size = New-Object System.Drawing.Size(200, 28); $responseBox.Text = [string]$Node.Config.ResponseVar; $form.Controls.Add($responseBox)
            Add-UiLabel $form '期望业务码' 354 397 96 24 | Out-Null
            $expectedBox = New-Object System.Windows.Forms.TextBox
            $expectedBox.Location = New-Object System.Drawing.Point(458, 394); $expectedBox.Size = New-Object System.Drawing.Size(132, 28); $expectedBox.Text = [string]$Node.Config.ExpectedCode; $form.Controls.Add($expectedBox)
            Add-UiLabel $form '模板示例：{{env.NAME}}、{{var.login.data}}、{{date:yyyy-MM-dd}}' 142 433 448 28 -Muted | Out-Null
        }
        'Cmd' {
            Add-UiLabel $form 'CMD 命令' 24 110 110 24 | Out-Null
            $commandBox = New-Object System.Windows.Forms.TextBox
            $commandBox.Location = New-Object Drawing.Point(142,107); $commandBox.Size = New-Object Drawing.Size(448,150); $commandBox.Multiline = $true; $commandBox.ScrollBars = 'Both'; $commandBox.AcceptsReturn = $true; $commandBox.AcceptsTab = $true; $commandBox.WordWrap = $false; $commandBox.Font = New-Object Drawing.Font('Consolas',9); $commandBox.Text = [string](Get-UiConfigValue $Node.Config 'Command' ''); $form.Controls.Add($commandBox)
            Add-UiLabel $form '工作目录' 24 272 110 24 | Out-Null
            $workingDirectoryBox = New-Object System.Windows.Forms.TextBox; $workingDirectoryBox.Location = New-Object Drawing.Point(142,269); $workingDirectoryBox.Size = New-Object Drawing.Size(448,28); $workingDirectoryBox.Text = [string](Get-UiConfigValue $Node.Config 'WorkingDirectory' ''); $form.Controls.Add($workingDirectoryBox)
            Add-UiLabel $form '超时（可选）' 24 316 110 24 | Out-Null
            $timeoutBox = New-Object System.Windows.Forms.TextBox; $timeoutBox.Location = New-Object Drawing.Point(142,313); $timeoutBox.Size = New-Object Drawing.Size(110,28); $timeoutBox.Text = [string](Get-UiConfigValue $Node.Config 'TimeoutSeconds' ''); $form.Controls.Add($timeoutBox)
            Add-UiLabel $form '结果变量' 276 316 82 24 | Out-Null
            $outputVarBox = New-Object System.Windows.Forms.TextBox; $outputVarBox.Location = New-Object Drawing.Point(360,313); $outputVarBox.Size = New-Object Drawing.Size(230,28); $outputVarBox.Text = [string](Get-UiConfigValue $Node.Config 'OutputVar' 'cmdResult'); $form.Controls.Add($outputVarBox)
            $failOnErrorBox = New-Object System.Windows.Forms.CheckBox; $failOnErrorBox.Location = New-Object Drawing.Point(142,357); $failOnErrorBox.Size = New-Object Drawing.Size(260,26); $failOnErrorBox.Text = '非零退出码时终止工作流'; $failOnErrorBox.Checked = [bool](Get-UiConfigValue $Node.Config 'FailOnError' $true); $form.Controls.Add($failOnErrorBox)
            Add-UiLabel $form '留空表示无限等待，任务会停留在当前 CMD 节点并持续采集输出，可在“运行中任务”中停止；填写秒数则在超时后终止。' 142 394 448 58 -Muted | Out-Null
        }
        'Python' {
            Add-UiLabel $form '执行方式' 24 110 110 24 | Out-Null
            $pythonModeBox=New-Object Windows.Forms.ComboBox;$pythonModeBox.Location=New-Object Drawing.Point(142,107);$pythonModeBox.Size=New-Object Drawing.Size(180,28);$pythonModeBox.DropDownStyle='DropDownList';$pythonModeBox.DisplayMember='Text';$pythonModeBox.ValueMember='Value'
            foreach($option in @([pscustomobject]@{Text='内联 Python 代码';Value='Inline'},[pscustomobject]@{Text='Python 脚本文件';Value='File'})){[void]$pythonModeBox.Items.Add($option)}
            $pythonMode=[string](Get-UiConfigValue $Node.Config 'Mode' 'Inline');$pythonModeBox.SelectedIndex=if($pythonMode-eq'File'){1}else{0};$form.Controls.Add($pythonModeBox)
            Add-UiLabel $form '代码 / 文件路径' 24 152 110 24 | Out-Null
            $pythonScriptBox=New-Object Windows.Forms.TextBox;$pythonScriptBox.Location=New-Object Drawing.Point(142,149);$pythonScriptBox.Size=New-Object Drawing.Size(448,150);$pythonScriptBox.Multiline=$true;$pythonScriptBox.ScrollBars='Both';$pythonScriptBox.AcceptsReturn=$true;$pythonScriptBox.AcceptsTab=$true;$pythonScriptBox.WordWrap=$false;$pythonScriptBox.Font=New-Object Drawing.Font('Consolas',9);$pythonScriptBox.Text=[string](Get-UiConfigValue $Node.Config 'Script' '');$form.Controls.Add($pythonScriptBox)
            Add-UiLabel $form '工作目录' 24 314 110 24 | Out-Null
            $pythonWorkingDirectoryBox=New-Object Windows.Forms.TextBox;$pythonWorkingDirectoryBox.Location=New-Object Drawing.Point(142,311);$pythonWorkingDirectoryBox.Size=New-Object Drawing.Size(448,28);$pythonWorkingDirectoryBox.Text=[string](Get-UiConfigValue $Node.Config 'WorkingDirectory' '');$form.Controls.Add($pythonWorkingDirectoryBox)
            Add-UiLabel $form '启动参数' 24 356 110 24 | Out-Null
            $pythonArgumentsBox=New-Object Windows.Forms.TextBox;$pythonArgumentsBox.Location=New-Object Drawing.Point(142,353);$pythonArgumentsBox.Size=New-Object Drawing.Size(448,60);$pythonArgumentsBox.Multiline=$true;$pythonArgumentsBox.ScrollBars='Horizontal';$pythonArgumentsBox.WordWrap=$false;$pythonArgumentsBox.Text=[string](Get-UiConfigValue $Node.Config 'Arguments' '');$form.Controls.Add($pythonArgumentsBox)
            Add-UiLabel $form '超时（可选）' 24 434 110 24 | Out-Null
            $pythonTimeoutBox=New-Object Windows.Forms.TextBox;$pythonTimeoutBox.Location=New-Object Drawing.Point(142,431);$pythonTimeoutBox.Size=New-Object Drawing.Size(110,28);$pythonTimeoutBox.Text=[string](Get-UiConfigValue $Node.Config 'TimeoutSeconds' '');$form.Controls.Add($pythonTimeoutBox)
            Add-UiLabel $form '结果变量' 276 434 82 24 | Out-Null
            $pythonOutputVarBox=New-Object Windows.Forms.TextBox;$pythonOutputVarBox.Location=New-Object Drawing.Point(360,431);$pythonOutputVarBox.Size=New-Object Drawing.Size(230,28);$pythonOutputVarBox.Text=[string](Get-UiConfigValue $Node.Config 'OutputVar' 'pythonResult');$form.Controls.Add($pythonOutputVarBox)
            $pythonFailOnErrorBox=New-Object Windows.Forms.CheckBox;$pythonFailOnErrorBox.Location=New-Object Drawing.Point(142,473);$pythonFailOnErrorBox.Size=New-Object Drawing.Size(260,26);$pythonFailOnErrorBox.Text='非零退出码时终止工作流';$pythonFailOnErrorBox.Checked=[bool](Get-UiConfigValue $Node.Config 'FailOnError' $true);$form.Controls.Add($pythonFailOnErrorBox)
            Add-UiLabel $form '解释器读取全局配置；工作目录留空时继承项目目录。支持 {{var.xxx}} / {{env.xxx}} 模板，超时留空表示持续等待并实时采集输出。' 142 506 448 58 -Muted | Out-Null
        }
        'Codex' {
            Add-UiLabel $form '全局 Codex' 24 110 110 24 | Out-Null
            $globalCodexBox = New-Object Windows.Forms.TextBox; $globalCodexBox.Location = New-Object Drawing.Point(142,107); $globalCodexBox.Size = New-Object Drawing.Size(448,28); $globalCodexBox.ReadOnly = $true; $globalCodexBox.Text = [string]$script:GlobalSettings.CodexPath; $form.Controls.Add($globalCodexBox)
            Add-UiLabel $form '工作目录（可选）' 24 152 110 24 | Out-Null
            $codexWorkingDirectoryBox = New-Object Windows.Forms.TextBox; $codexWorkingDirectoryBox.Location = New-Object Drawing.Point(142,149); $codexWorkingDirectoryBox.Size = New-Object Drawing.Size(448,28); $codexWorkingDirectoryBox.Text = [string](Get-UiConfigValue $Node.Config 'WorkingDirectory' ''); $form.Controls.Add($codexWorkingDirectoryBox)
            Add-UiLabel $form '会话 ID（可选）' 24 194 110 24 | Out-Null
            $codexSessionIdBox = New-Object Windows.Forms.TextBox; $codexSessionIdBox.Location = New-Object Drawing.Point(142,191); $codexSessionIdBox.Size = New-Object Drawing.Size(448,28); $codexSessionIdBox.Text = [string](Get-UiConfigValue $Node.Config 'SessionId' ''); $form.Controls.Add($codexSessionIdBox)
            Add-UiLabel $form '需求内容' 24 236 110 24 | Out-Null
            $codexRequestBox = New-Object Windows.Forms.TextBox; $codexRequestBox.Location = New-Object Drawing.Point(142,233); $codexRequestBox.Size = New-Object Drawing.Size(448,96); $codexRequestBox.Multiline = $true; $codexRequestBox.ScrollBars = 'Vertical'; $codexRequestBox.AcceptsReturn = $true; $codexRequestBox.Text = [string](Get-UiConfigValue $Node.Config 'Request' ''); $form.Controls.Add($codexRequestBox)
            Add-UiLabel $form '可选实时数据' 24 346 110 24 | Out-Null
            $codexLiveDataBox = New-Object Windows.Forms.TextBox; $codexLiveDataBox.Location = New-Object Drawing.Point(142,343); $codexLiveDataBox.Size = New-Object Drawing.Size(448,82); $codexLiveDataBox.Multiline = $true; $codexLiveDataBox.ScrollBars = 'Vertical'; $codexLiveDataBox.AcceptsReturn = $true; $codexLiveDataBox.Text = [string](Get-UiConfigValue $Node.Config 'LiveData' ''); $form.Controls.Add($codexLiveDataBox)
            Add-UiLabel $form '超时（秒）' 24 444 110 24 | Out-Null
            $codexTimeoutBox = New-Object Windows.Forms.NumericUpDown; $codexTimeoutBox.Location = New-Object Drawing.Point(142,441); $codexTimeoutBox.Size = New-Object Drawing.Size(110,28); $codexTimeoutBox.Minimum = 1; $codexTimeoutBox.Maximum = 86400; $codexTimeoutBox.Value = [Math]::Min(86400,[Math]::Max(1,[int](Get-UiConfigValue $Node.Config 'TimeoutSeconds' 600))); $form.Controls.Add($codexTimeoutBox)
            Add-UiLabel $form '结果变量' 276 444 82 24 | Out-Null
            $codexOutputVarBox = New-Object Windows.Forms.TextBox; $codexOutputVarBox.Location = New-Object Drawing.Point(360,441); $codexOutputVarBox.Size = New-Object Drawing.Size(230,28); $codexOutputVarBox.Text = [string](Get-UiConfigValue $Node.Config 'OutputVar' 'codexResult'); $form.Controls.Add($codexOutputVarBox)
            $codexFailOnErrorBox = New-Object Windows.Forms.CheckBox; $codexFailOnErrorBox.Location = New-Object Drawing.Point(142,479); $codexFailOnErrorBox.Size = New-Object Drawing.Size(280,26); $codexFailOnErrorBox.Text = '非零退出码时终止工作流'; $codexFailOnErrorBox.Checked = [bool](Get-UiConfigValue $Node.Config 'FailOnError' $true); $form.Controls.Add($codexFailOnErrorBox)
            Add-UiLabel $form '工作目录和会话 ID 留空时继承项目配置；无项目时工作目录使用 %TEMP%。' 142 514 448 54 -Muted | Out-Null
        }
        'EnvRead' {
            Add-UiLabel $form '环境变量映射' 24 110 160 24 | Out-Null
            Add-UiLabel $form '从 Windows/任务环境导入为任务变量，可一次配置多行。' 190 110 400 24 -Muted | Out-Null
            $envGrid = New-EnvironmentGrid $form 145 '环境变量名' '任务变量名' (Get-UiEnvironmentItems $Node.Config -Read)
            $removeRows = Add-UiButton $form '删除选中行' 24 425 110 32 'Danger'
            $removeRows.Add_Click({ foreach ($row in @($envGrid.SelectedRows | Sort-Object Index -Descending)) { if (-not $row.IsNewRow) { $envGrid.Rows.Remove($row) } } })
            Add-UiLabel $form '提示：写入节点定义的变量可直接用 {{var.NAME}} 引用，无需再连接读取节点。' 142 429 448 42 -Muted | Out-Null
        }
        'EnvWrite' {
            Add-UiLabel $form '任务变量和值' 24 110 160 24 | Out-Null
            Add-UiLabel $form '直接定义本次任务使用的变量和值，CMD 节点也会继承这些变量。' 190 110 400 24 -Muted | Out-Null
            $envGrid = New-EnvironmentGrid $form 145 '变量名' '值 / 模板' (Get-UiEnvironmentItems $Node.Config) -IncludeLabel
            $removeRows = Add-UiButton $form '删除选中行' 24 425 110 32 'Danger'
            $removeRows.Add_Click({ foreach ($row in @($envGrid.SelectedRows | Sort-Object Index -Descending)) { if (-not $row.IsNewRow) { $envGrid.Rows.Remove($row) } } })
            $envInlineEditBox = New-Object Windows.Forms.CheckBox; $envInlineEditBox.Location = New-Object Drawing.Point(142,425); $envInlineEditBox.Size = New-Object Drawing.Size(448,28); $envInlineEditBox.Text = '在画布节点中直接显示和编辑这些变量'; $envInlineEditBox.Checked = [bool](Get-UiConfigValue $Node.Config 'InlineEdit' $false); $form.Controls.Add($envInlineEditBox)
            Add-UiLabel $form '显示名用于画布；布尔值可在画布上单击“是/否”直接切换。' 142 456 448 42 -Muted | Out-Null
        }
        'Variable' {
            Add-UiLabel $form '变量名' 24 120 110 24 | Out-Null
            $variableNameBox = New-Object Windows.Forms.TextBox; $variableNameBox.Location = New-Object Drawing.Point(142,117); $variableNameBox.Size = New-Object Drawing.Size(448,28); $variableNameBox.Text = [string](Get-UiConfigValue $Node.Config 'Name' 'result'); $form.Controls.Add($variableNameBox)
            Add-UiLabel $form '值类型' 24 164 110 24 | Out-Null
            $variableTypeBox = New-Object Windows.Forms.ComboBox; $variableTypeBox.Location = New-Object Drawing.Point(142,161); $variableTypeBox.Size = New-Object Drawing.Size(180,28); $variableTypeBox.DropDownStyle = 'DropDownList'; $variableTypeBox.DisplayMember = 'Text'; $variableTypeBox.ValueMember = 'Value'
            foreach ($option in @([pscustomobject]@{Text='文本';Value='String'},[pscustomobject]@{Text='数字';Value='Number'},[pscustomobject]@{Text='布尔值';Value='Boolean'},[pscustomobject]@{Text='JSON';Value='Json'})) { [void]$variableTypeBox.Items.Add($option) }
            $selectedType = [string](Get-UiConfigValue $Node.Config 'ValueType' 'String'); $variableTypeBox.SelectedItem = Get-UiIndexedItemSafe @($variableTypeBox.Items | Where-Object Value -eq $selectedType | Select-Object -First 1) 0; if ($null -eq $variableTypeBox.SelectedItem) { $variableTypeBox.SelectedIndex = 0 }; $form.Controls.Add($variableTypeBox)
            Add-UiLabel $form '值 / 模板' 24 208 110 24 | Out-Null
            $variableValueBox = New-Object Windows.Forms.TextBox; $variableValueBox.Location = New-Object Drawing.Point(142,205); $variableValueBox.Size = New-Object Drawing.Size(448,170); $variableValueBox.Multiline = $true; $variableValueBox.ScrollBars = 'Vertical'; $variableValueBox.Text = [string](Get-UiConfigValue $Node.Config 'Value' ''); $form.Controls.Add($variableValueBox)
        }
        'If' {
            Add-UiLabel $form '左值 / 模板' 24 112 110 24 | Out-Null
            $ifLeftBox = New-Object Windows.Forms.TextBox; $ifLeftBox.Location = New-Object Drawing.Point(142,109); $ifLeftBox.Size = New-Object Drawing.Size(448,64); $ifLeftBox.Multiline = $true; $ifLeftBox.Text = [string](Get-UiConfigValue $Node.Config 'Left' ''); $form.Controls.Add($ifLeftBox)
            Add-UiLabel $form '判断方式' 24 193 110 24 | Out-Null
            $ifOperatorBox = New-Object Windows.Forms.ComboBox; $ifOperatorBox.Location = New-Object Drawing.Point(142,190); $ifOperatorBox.Size = New-Object Drawing.Size(220,28); $ifOperatorBox.DropDownStyle = 'DropDownList'; $ifOperatorBox.DisplayMember = 'Text'; $ifOperatorBox.ValueMember = 'Value'
            $operators = @([pscustomobject]@{Text='等于';Value='Equals'},[pscustomobject]@{Text='不等于';Value='NotEquals'},[pscustomobject]@{Text='包含';Value='Contains'},[pscustomobject]@{Text='不包含';Value='NotContains'},[pscustomobject]@{Text='大于';Value='GreaterThan'},[pscustomobject]@{Text='大于等于';Value='GreaterOrEqual'},[pscustomobject]@{Text='小于';Value='LessThan'},[pscustomobject]@{Text='小于等于';Value='LessOrEqual'},[pscustomobject]@{Text='为空';Value='IsEmpty'},[pscustomobject]@{Text='不为空';Value='NotEmpty'},[pscustomobject]@{Text='正则匹配';Value='Matches'})
            foreach ($option in $operators) { [void]$ifOperatorBox.Items.Add($option) }
            $selectedOperator = [string](Get-UiConfigValue $Node.Config 'Operator' 'Equals'); $ifOperatorBox.SelectedItem = Get-UiIndexedItemSafe @($ifOperatorBox.Items | Where-Object Value -eq $selectedOperator | Select-Object -First 1) 0; if ($null -eq $ifOperatorBox.SelectedItem) { $ifOperatorBox.SelectedIndex = 0 }; $form.Controls.Add($ifOperatorBox)
            Add-UiLabel $form '右值 / 模板' 24 238 110 24 | Out-Null
            $ifRightBox = New-Object Windows.Forms.TextBox; $ifRightBox.Location = New-Object Drawing.Point(142,235); $ifRightBox.Size = New-Object Drawing.Size(448,64); $ifRightBox.Multiline = $true; $ifRightBox.Text = [string](Get-UiConfigValue $Node.Config 'Right' ''); $form.Controls.Add($ifRightBox)
            Add-UiLabel $form '结果变量' 24 323 110 24 | Out-Null
            $ifOutputBox = New-Object Windows.Forms.TextBox; $ifOutputBox.Location = New-Object Drawing.Point(142,320); $ifOutputBox.Size = New-Object Drawing.Size(220,28); $ifOutputBox.Text = [string](Get-UiConfigValue $Node.Config 'OutputVar' 'conditionResult'); $form.Controls.Add($ifOutputBox)
        }
        'ForEach' {
            Add-UiLabel $form '集合 / JSON' 24 112 110 24 | Out-Null
            $loopItemsBox = New-Object Windows.Forms.TextBox; $loopItemsBox.Location = New-Object Drawing.Point(142,109); $loopItemsBox.Size = New-Object Drawing.Size(448,130); $loopItemsBox.Multiline = $true; $loopItemsBox.ScrollBars = 'Vertical'; $loopItemsBox.Text = [string](Get-UiConfigValue $Node.Config 'Items' '[]'); $form.Controls.Add($loopItemsBox)
            Add-UiLabel $form '当前项变量' 24 265 110 24 | Out-Null
            $loopItemVariableBox = New-Object Windows.Forms.TextBox; $loopItemVariableBox.Location = New-Object Drawing.Point(142,262); $loopItemVariableBox.Size = New-Object Drawing.Size(190,28); $loopItemVariableBox.Text = [string](Get-UiConfigValue $Node.Config 'ItemVariable' 'item'); $form.Controls.Add($loopItemVariableBox)
            Add-UiLabel $form '序号变量' 350 265 82 24 | Out-Null
            $loopIndexVariableBox = New-Object Windows.Forms.TextBox; $loopIndexVariableBox.Location = New-Object Drawing.Point(438,262); $loopIndexVariableBox.Size = New-Object Drawing.Size(152,28); $loopIndexVariableBox.Text = [string](Get-UiConfigValue $Node.Config 'IndexVariable' 'index'); $form.Controls.Add($loopIndexVariableBox)
            Add-UiLabel $form '循环结果变量' 24 310 110 24 | Out-Null
            $loopResultVariableBox = New-Object Windows.Forms.TextBox; $loopResultVariableBox.Location = New-Object Drawing.Point(142,307); $loopResultVariableBox.Size = New-Object Drawing.Size(190,28); $loopResultVariableBox.Text = [string](Get-UiConfigValue $Node.Config 'ResultVariable' 'loopResult'); $form.Controls.Add($loopResultVariableBox)
        }
        'LoopEnd' { }
        'Delay' {
            Add-UiLabel $form '延时秒数' 24 120 110 24 | Out-Null
            $delaySecondsBox = New-Object Windows.Forms.NumericUpDown; $delaySecondsBox.Location = New-Object Drawing.Point(142,117); $delaySecondsBox.Size = New-Object Drawing.Size(160,28); $delaySecondsBox.Minimum = 0; $delaySecondsBox.Maximum = 86400; $delaySecondsBox.DecimalPlaces = 1; $delaySecondsBox.Increment = [decimal]0.5; $delayValue = [decimal](Get-UiConfigValue $Node.Config 'Seconds' 1); $delaySecondsBox.Value = [Math]::Min([decimal]86400,[Math]::Max([decimal]0,$delayValue)); $form.Controls.Add($delaySecondsBox)
        }
        'Balloon' {
            Add-UiLabel $form '气泡标题' 24 120 110 24 | Out-Null
            $titleBox = New-Object System.Windows.Forms.TextBox; $titleBox.Location = New-Object Drawing.Point(142,117); $titleBox.Size = New-Object Drawing.Size(448,28); $titleBox.Text = [string]$Node.Config.Title; $form.Controls.Add($titleBox)
            Add-UiLabel $form '提醒内容' 24 164 110 24 | Out-Null
            $messageBox = New-Object System.Windows.Forms.TextBox; $messageBox.Location = New-Object Drawing.Point(142,161); $messageBox.Size = New-Object Drawing.Size(448,110); $messageBox.Multiline = $true; $messageBox.Text = [string]$Node.Config.Message; $form.Controls.Add($messageBox)
            Add-UiLabel $form '点击行为' 24 294 110 24 | Out-Null
            $balloonActionBox = New-Object Windows.Forms.ComboBox; $balloonActionBox.Location = New-Object Drawing.Point(142,291); $balloonActionBox.Size = New-Object Drawing.Size(210,28); $balloonActionBox.DropDownStyle = 'DropDownList'; $balloonActionBox.DisplayMember = 'Text'; $balloonActionBox.ValueMember = 'Value'
            foreach ($option in @([pscustomobject]@{Text='无动作';Value='None'},[pscustomobject]@{Text='打开文件或目录';Value='OpenPath'},[pscustomobject]@{Text='浏览器打开 URL';Value='OpenUrl'})) { [void]$balloonActionBox.Items.Add($option) }
            $selectedAction = [string](Get-UiConfigValue $Node.Config 'ClickAction' 'None'); $balloonActionBox.SelectedIndex = 0
            for ($index = 0; $index -lt $balloonActionBox.Items.Count; $index++) { if ([string]$balloonActionBox.Items[$index].Value -eq $selectedAction) { $balloonActionBox.SelectedIndex = $index; break } }
            $form.Controls.Add($balloonActionBox)
            Add-UiLabel $form '点击目标' 24 338 110 24 | Out-Null
            $balloonTargetBox = New-Object Windows.Forms.TextBox; $balloonTargetBox.Location = New-Object Drawing.Point(142,335); $balloonTargetBox.Size = New-Object Drawing.Size(448,28); $balloonTargetBox.Text = [string](Get-UiConfigValue $Node.Config 'ClickTarget' ''); $form.Controls.Add($balloonTargetBox)
            Add-UiLabel $form '支持路径、http/https URL 和 {{var.xxx}} / {{env.xxx}} 模板；后显示的气泡会替换前一个点击目标。' 142 370 448 44 -Muted | Out-Null
        }
    }
    $save = Add-UiButton $form '保存节点' 458 588 132 34 'Primary'
    $cancel = Add-UiButton $form '取消' 350 588 96 34; $cancel.DialogResult = 'Cancel'; $form.CancelButton = $cancel
    $save.Add_Click({
        if ([string]::IsNullOrWhiteSpace($nameBox.Text)) { Show-Message '节点名称不能为空。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
        $environmentItems = $null
        if ($Node.Type -eq 'EnvRead' -or $Node.Type -eq 'EnvWrite') {
            try {
                if ($Node.Type -eq 'EnvRead') { $environmentItems = @(Get-EnvironmentGridItems $envGrid -Read) }
                else { $environmentItems = @(Get-EnvironmentGridItems $envGrid -IncludeLabel) }
            } catch { Show-Message ('变量表格无效：' + $_.Exception.Message) '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
            if ($environmentItems.Count -eq 0) { Show-Message '至少需要配置一行变量映射。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
        }
        $cmdTimeoutValue = ''
        if ($Node.Type -eq 'Cmd') {
            if ([string]::IsNullOrWhiteSpace($commandBox.Text)) { Show-Message 'CMD 命令不能为空。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
            $cmdTimeoutText = $timeoutBox.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($cmdTimeoutText)) {
                $parsedCmdTimeout = 0
                if (-not [int]::TryParse($cmdTimeoutText, [ref]$parsedCmdTimeout) -or $parsedCmdTimeout -lt 1 -or $parsedCmdTimeout -gt 86400) { Show-Message 'CMD 超时请留空，或填写 1 到 86400 的整数秒数。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
                $cmdTimeoutValue = $parsedCmdTimeout
            }
        }
        $pythonTimeoutValue=''
        if($Node.Type-eq'Python'){
            if([string]::IsNullOrWhiteSpace($pythonScriptBox.Text)){Show-Message 'Python 代码或脚本文件路径不能为空。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
            $pythonTimeoutText=$pythonTimeoutBox.Text.Trim()
            if(-not[string]::IsNullOrWhiteSpace($pythonTimeoutText)){
                $parsedPythonTimeout=0
                if(-not[int]::TryParse($pythonTimeoutText,[ref]$parsedPythonTimeout)-or$parsedPythonTimeout-lt1-or$parsedPythonTimeout-gt86400){Show-Message 'Python 超时请留空，或填写 1 到 86400 的整数秒数。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning);return}
                $pythonTimeoutValue=$parsedPythonTimeout
            }
        }
        if ($Node.Type -eq 'Codex') {
            if ([string]::IsNullOrWhiteSpace($codexRequestBox.Text)) { Show-Message '需求内容不能为空。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
        }
        if ($Node.Type -eq 'Variable' -and [string]::IsNullOrWhiteSpace($variableNameBox.Text)) { Show-Message '变量名不能为空。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
        if ($Node.Type -eq 'ForEach' -and [string]::IsNullOrWhiteSpace($loopItemVariableBox.Text)) { Show-Message '当前项变量名不能为空。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
        $Node.Name = $nameBox.Text.Trim()
        if ($Node.Type -eq 'Balloon' -and $null -ne $balloonActionBox.SelectedItem -and [string]$balloonActionBox.SelectedItem.Value -ne 'None' -and [string]::IsNullOrWhiteSpace($balloonTargetBox.Text)) { Show-Message '配置点击行为后，点击目标不能为空。' '节点配置' ([Windows.Forms.MessageBoxIcon]::Warning); return }
        switch ($Node.Type) {
            'HttpRequest' { $Node.Config = [pscustomobject]@{ Method = [string]$methodBox.SelectedItem; Url = $urlBox.Text.Trim(); Headers = $headersBox.Text; Body = $bodyBox.Text; ResponseVar = $responseBox.Text.Trim(); ExpectedCode = $expectedBox.Text.Trim() } }
            'Cmd' { $Node.Config = [pscustomobject]@{ Command = $commandBox.Text; WorkingDirectory = $workingDirectoryBox.Text.Trim(); TimeoutSeconds = $cmdTimeoutValue; OutputVar = $outputVarBox.Text.Trim(); FailOnError = [bool]$failOnErrorBox.Checked } }
            'Python' { $Node.Config = [pscustomobject]@{ Mode = [string]$pythonModeBox.SelectedItem.Value; Script = $pythonScriptBox.Text; WorkingDirectory = $pythonWorkingDirectoryBox.Text.Trim(); Arguments = $pythonArgumentsBox.Text.Trim(); TimeoutSeconds = $pythonTimeoutValue; OutputVar = $pythonOutputVarBox.Text.Trim(); FailOnError = [bool]$pythonFailOnErrorBox.Checked } }
            'Codex' { $Node.Config = [pscustomobject]@{ WorkingDirectory = $codexWorkingDirectoryBox.Text.Trim(); SessionId = $codexSessionIdBox.Text.Trim(); Request = $codexRequestBox.Text; LiveData = $codexLiveDataBox.Text; TimeoutSeconds = [int]$codexTimeoutBox.Value; OutputVar = $codexOutputVarBox.Text.Trim(); FailOnError = [bool]$codexFailOnErrorBox.Checked } }
            'EnvRead' { $Node.Config = [pscustomobject]@{ Items = @($environmentItems) } }
            'EnvWrite' { $Node.Config = [pscustomobject]@{ Items = @($environmentItems); InlineEdit = [bool]$envInlineEditBox.Checked }; [void](Sync-InlineVariableNodeLayout $Node) }
            'Variable' { $Node.Config = [pscustomobject]@{ Name = $variableNameBox.Text.Trim(); ValueType = [string]$variableTypeBox.SelectedItem.Value; Value = $variableValueBox.Text } }
            'If' { $Node.Config = [pscustomobject]@{ Left = $ifLeftBox.Text; Operator = [string]$ifOperatorBox.SelectedItem.Value; Right = $ifRightBox.Text; OutputVar = $ifOutputBox.Text.Trim() } }
            'ForEach' { $Node.Config = [pscustomobject]@{ Items = $loopItemsBox.Text; ItemVariable = $loopItemVariableBox.Text.Trim(); IndexVariable = $loopIndexVariableBox.Text.Trim(); ResultVariable = $loopResultVariableBox.Text.Trim() } }
            'LoopEnd' { $Node.Config = [pscustomobject]@{} }
            'Delay' { $Node.Config = [pscustomobject]@{ Seconds = [double]$delaySecondsBox.Value } }
            'Balloon' { $Node.Config = [pscustomobject]@{ Title = $titleBox.Text; Message = $messageBox.Text; ClickAction = [string]$balloonActionBox.SelectedItem.Value; ClickTarget = $balloonTargetBox.Text } }
        }
        $form.DialogResult = 'OK'; $form.Close()
    })
    Apply-UiTheme $form
    try{return $form.ShowDialog($script:MainForm)}
    finally{if($null-ne$form-and-not$form.IsDisposed){$form.Dispose()}}
}

function Add-NewNode {
    param([string]$Type)
    if ($null -eq $script:CurrentWorkflow) { return }
    if ($Type -eq 'Start' -or $Type -eq 'End') {
        $existing = @($script:CurrentWorkflow.Nodes | Where-Object Type -eq $Type | Select-Object -First 1)
        if ($existing.Count -gt 0) {
            $script:SelectedNode = $existing[0]
            $script:SelectedEdge = $null
            $script:Canvas.Invalidate()
            Show-Message "当前工作流已经有$((Get-NodeTypeLabel $Type))节点。删除多余节点后再添加。" '添加节点' ([Windows.Forms.MessageBoxIcon]::Information)
            return
        }
    }
    $defaults = switch ($Type) {
        'Start' { @('开始', [pscustomobject]@{}) }
        'End' { @('结束', [pscustomobject]@{}) }
        'HttpRequest' { @('网络请求', [pscustomobject]@{ Method = 'GET'; Url = ''; Headers = '{"Content-Type":"application/json"}'; Body = ''; ResponseVar = 'response'; ExpectedCode = '' }) }
        'Cmd' { @('执行 CMD', [pscustomobject]@{ Command = ''; WorkingDirectory = ''; TimeoutSeconds = ''; OutputVar = 'cmdResult'; FailOnError = $true }) }
        'Python' { @('执行 Python', [pscustomobject]@{ Mode = 'Inline'; Script = "print('Hello from 使驾')"; WorkingDirectory = ''; Arguments = ''; TimeoutSeconds = ''; OutputVar = 'pythonResult'; FailOnError = $true }) }
        'Codex' { @('调用 Codex', [pscustomobject]@{ WorkingDirectory = ''; SessionId = ''; Request = ''; LiveData = ''; TimeoutSeconds = 600; OutputVar = 'codexResult'; FailOnError = $true }) }
        'EnvRead' { @('导入环境变量', [pscustomobject]@{ Items = @() }) }
        'EnvWrite' { @('定义任务变量', [pscustomobject]@{ Items = @() }) }
        'Variable' { @('变量赋值', [pscustomobject]@{ Name = 'result'; ValueType = 'String'; Value = '' }) }
        'If' { @('条件判断', [pscustomobject]@{ Left = ''; Operator = 'Equals'; Right = ''; OutputVar = 'conditionResult' }) }
        'ForEach' { @('遍历循环', [pscustomobject]@{ Items = '[]'; ItemVariable = 'item'; IndexVariable = 'index'; ResultVariable = 'loopResult' }) }
        'LoopEnd' { @('循环结束', [pscustomobject]@{}) }
        'Delay' { @('延时等待', [pscustomobject]@{ Seconds = 1 }) }
        'Balloon' { @('Windows 气泡提醒', [pscustomobject]@{ Title = '工作流提醒'; Message = '任务执行完成。'; ClickAction = 'None'; ClickTarget = '' }) }
    }
    $count = @($script:CurrentWorkflow.Nodes).Count
    $node = New-WorkflowNode $Type $defaults[0] (50 + (($count % 4) * 220)) (60 + ([math]::Floor($count / 4) * 120)) $defaults[1]
    $script:CurrentWorkflow.Nodes = @($script:CurrentWorkflow.Nodes) + $node
    if ((Show-NodeEditor $node) -ne 'OK') { $script:CurrentWorkflow.Nodes = @($script:CurrentWorkflow.Nodes | Where-Object Id -ne $node.Id); return }
    $script:SelectedNode = $node
    $script:SelectedEdge = $null
    $script:Canvas.Invalidate()
}

function Write-WorkflowLog {
    param([string]$Message, [string]$Level = 'INFO')
    Ensure-DataDirectories
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    [IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    Append-WorkflowLogText ($line + [Environment]::NewLine) 1
}

function Append-WorkflowLogText {
    param([string]$Text,[int]$LineCount=1)
    if([string]::IsNullOrEmpty($Text)-or$null-eq$script:LogBox-or$script:LogBox.IsDisposed){return}
    $script:LogBox.AppendText($Text)
    $script:GlobalLogVisibleLineCount+=[Math]::Max(1,$LineCount)
    if($script:GlobalLogVisibleLineCount-gt2000){
        $removeLineCount=$script:GlobalLogVisibleLineCount-1200
        $firstRemainingCharacter=$script:LogBox.GetFirstCharIndexFromLine($removeLineCount)
        if($firstRemainingCharacter-gt0){
            $script:LogBox.Select(0,$firstRemainingCharacter)
            $script:LogBox.SelectedText=''
            $script:GlobalLogVisibleLineCount-=$removeLineCount
        }
    }
    $script:LogBox.SelectionStart=$script:LogBox.TextLength
    $script:LogBox.SelectionLength=0
    $script:LogBox.ScrollToCaret()
}

function Write-WorkflowLogBatch {
    param([object[]]$Entries)
    $items=@($Entries)
    if($items.Count-eq0){return}
    Ensure-DataDirectories
    $builder=New-Object Text.StringBuilder
    foreach($entry in $items){
        $at=Get-Date
        if($null-ne$entry.PSObject.Properties['At']-and-not[string]::IsNullOrWhiteSpace([string]$entry.At)){try{$at=([datetime]$entry.At).ToLocalTime()}catch{}}
        $level=if($null-ne$entry.PSObject.Properties['Level']){[string]$entry.Level}else{'INFO'}
        [void]$builder.AppendLine(('{0} [{1}] {2}'-f$at.ToString('yyyy-MM-dd HH:mm:ss'),$level,[string]$entry.Message))
    }
    $text=$builder.ToString();[IO.File]::AppendAllText($script:LogPath,$text,[Text.Encoding]::UTF8)
    Append-WorkflowLogText $text $items.Count
}

function Stop-WorkflowProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    try {
        $taskKillPath = Join-Path $env:WINDIR 'System32\taskkill.exe'
        $process = Start-Process -FilePath $taskKillPath -ArgumentList @('/PID',[string]$ProcessId,'/T','/F') -WindowStyle Hidden -PassThru -Wait
        if ($null -ne $process) { $process.Dispose() }
    } catch {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Add-RunningTaskLog {
    param($Record, [string]$Message, [string]$Level = 'INFO', [string]$Kind = 'Log', [string]$At = '')
    if ($null -eq $Record) { return }
    if ($null -eq $Record.Logs) { $Record.Logs = New-Object System.Collections.ArrayList }
    if ([string]::IsNullOrWhiteSpace($At)) { $At = (Get-Date).ToString('o') }
    [void]$Record.Logs.Add([pscustomobject]@{ At=$At; Level=$Level; Kind=$Kind; Message=$Message })
    if ($Record.Logs.Count -gt 3000) {
        $Record.Logs.RemoveRange(0,500)
        if([string]$script:RunningTaskDisplayedId-eq[string]$Record.WorkflowId){$script:RunningTaskDisplayedLogCount=[Math]::Max(0,$script:RunningTaskDisplayedLogCount-500);$script:RunningTaskLogNeedsReset=$true}
    }
}

function Read-WorkerEventLines {
    param($Worker,[int]$MaxBytes=262144,[int]$MaxLines=240)
    if ($null -eq $Worker -or -not (Test-Path -LiteralPath $Worker.OutputPath)) { return @() }
    $stream = New-Object IO.FileStream($Worker.OutputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $offset = [long]$Worker.ReadOffset
        if ($stream.Length -le $offset) { return @() }
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $remaining = [long]($stream.Length - $offset)
        $readLength=[int][Math]::Min($remaining,[Math]::Max(4096,$MaxBytes))
        $bytes = New-Object byte[] $readLength
        $readOffset = 0
        while ($readOffset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $readOffset, $bytes.Length - $readOffset)
            if ($read -le 0) { break }
            $readOffset += $read
        }
        $lastNewline = -1;$lineCount=0
        for ($index = 0; $index -lt $readOffset; $index++) { if ($bytes[$index] -eq 10) { $lastNewline=$index;$lineCount++;if($lineCount-ge[Math]::Max(1,$MaxLines)){break} } }
        if ($lastNewline -lt 0) { return @() }
        $completeLength = $lastNewline + 1
        $Worker.ReadOffset = $offset + $completeLength
        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $completeLength)
        return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } finally { $stream.Dispose() }
}

function Test-WorkerEventOutputDrained {
    param($Worker)
    if($null-eq$Worker-or-not(Test-Path -LiteralPath $Worker.OutputPath)){return $true}
    try{return (Get-Item -LiteralPath $Worker.OutputPath).Length-le[long]$Worker.ReadOffset}catch{return $false}
}

function Find-WorkflowById {
    param([string]$Id)
    if([string]::IsNullOrWhiteSpace($Id)){return $null}
    foreach($workflow in @($script:Workflows)){
        if([string]$workflow.Id-eq$Id){return $workflow}
    }
    return $null
}

function Get-WorkerPowerShellPath {
    $candidate = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return (Get-Command powershell.exe -ErrorAction Stop).Source
}

function Ensure-WorkerScriptFile {
    Ensure-DataDirectories
    $path = Join-Path $script:DataDirectory 'worker.ps1'
    [IO.File]::WriteAllText($path, $script:WorkerScript, (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

function Get-EffectiveWorkflowForRun {
    param($Workflow)
    $effective = (($Workflow | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json)
    $project = Get-WorkflowProject $Workflow
    $projectDirectory = if ($null -ne $project) { [string]$project.DefaultWorkingDirectory } else { '' }
    $projectSessionId = if ($null -ne $project) { [string]$project.CodexSessionId } else { '' }
    $projectModel = if ($null -ne $project) { [string](Get-UiConfigValue $project 'CodexModel' '') } else { '' }
    $globalCodexPath = if ($null -ne $script:GlobalSettings) { [string]$script:GlobalSettings.CodexPath } else { [string](New-DefaultGlobalSettings).CodexPath }
    $globalPythonInterpreterPath = if ($null -ne $script:GlobalSettings) { [string](Get-UiConfigValue $script:GlobalSettings 'PythonInterpreterPath' '') } else { '' }
    foreach ($node in @($effective.Nodes)) {
        if ($node.Type -eq 'Cmd') {
            $workingDirectory = [string](Get-UiConfigValue $node.Config 'WorkingDirectory' '')
            if ([string]::IsNullOrWhiteSpace($workingDirectory) -and -not [string]::IsNullOrWhiteSpace($projectDirectory)) { $node.Config.WorkingDirectory = $projectDirectory }
        }
        if ($node.Type -eq 'Codex') {
            if ($null -eq $node.Config.PSObject.Properties['CodexPath']) { $node.Config | Add-Member NoteProperty CodexPath $globalCodexPath }
            else { $node.Config.CodexPath = $globalCodexPath }
            $workingDirectory = [string](Get-UiConfigValue $node.Config 'WorkingDirectory' '')
            if ([string]::IsNullOrWhiteSpace($workingDirectory) -and -not [string]::IsNullOrWhiteSpace($projectDirectory)) { $node.Config.WorkingDirectory = $projectDirectory }
            $sessionId = [string](Get-UiConfigValue $node.Config 'SessionId' '')
            if ([string]::IsNullOrWhiteSpace($sessionId) -and -not [string]::IsNullOrWhiteSpace($projectSessionId)) { $node.Config.SessionId = $projectSessionId }
            if ([string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $node.Config 'Model' '')) -and -not [string]::IsNullOrWhiteSpace($projectModel)) {
                if ($null -eq $node.Config.PSObject.Properties['Model']) { $node.Config | Add-Member NoteProperty Model $projectModel } else { $node.Config.Model = $projectModel }
            }
        }
        if ($node.Type -eq 'Python') {
            $workingDirectory = [string](Get-UiConfigValue $node.Config 'WorkingDirectory' '')
            if ([string]::IsNullOrWhiteSpace($workingDirectory) -and -not [string]::IsNullOrWhiteSpace($projectDirectory)) { $node.Config.WorkingDirectory = $projectDirectory }
            $configuredInterpreter = [string](Get-UiConfigValue $node.Config 'InterpreterPath' '')
            if ([string]::IsNullOrWhiteSpace($configuredInterpreter)) {
                if ($null -eq $node.Config.PSObject.Properties['InterpreterPath']) { $node.Config | Add-Member NoteProperty InterpreterPath $globalPythonInterpreterPath } else { $node.Config.InterpreterPath = $globalPythonInterpreterPath }
            }
        }
    }
    return $effective
}

function Read-TextFileWithRetry {
    param([string]$Path, [int]$TimeoutMilliseconds = 3000, [int]$MaximumBytes = 8388608, [switch]$Tail)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    do {
        try {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $maximum = [Math]::Max(4096, $MaximumBytes)
                $truncated = $stream.Length -gt $maximum
                $start = if ($Tail -and $truncated) { [long]($stream.Length - $maximum) } else { [long]0 }
                [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
                $readLength = [int][Math]::Min([long]$maximum, $stream.Length - $start)
                $bytes = New-Object byte[] $readLength
                $offset = 0
                while ($offset -lt $readLength) {
                    $read = $stream.Read($bytes, $offset, $readLength - $offset)
                    if ($read -le 0) { break }
                    $offset += $read
                }
                $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $offset)
                if (-not $truncated) { return $text }
                if ($Tail) { return '[文件过长，仅保留末尾内容]' + [Environment]::NewLine + $text }
                return $text + [Environment]::NewLine + '[文件过长，后续内容已裁剪]'
            } finally { $stream.Dispose() }
        } catch { Start-Sleep -Milliseconds 100 }
    } while ((Get-Date) -lt $deadline)
    throw "无法读取 worker 输出文件：$Path"
}

function Start-WorkerProcess {
    param($Workflow)
    $runId = [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $script:DataDirectory 'runs'
    if (-not (Test-Path -LiteralPath $runDirectory)) { New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null }
    $inputPath = Join-Path $runDirectory ($runId + '.json')
    $outputPath = Join-Path $runDirectory ($runId + '.out')
    $errorPath = Join-Path $runDirectory ($runId + '.err')
    $effectiveWorkflow = Get-EffectiveWorkflowForRun $Workflow
    [IO.File]::WriteAllText($inputPath, ($effectiveWorkflow | ConvertTo-Json -Depth 30 -Compress), (New-Object System.Text.UTF8Encoding($true)))
    $workerPath = Ensure-WorkerScriptFile
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$workerPath,'-InputPath',$inputPath)
    $process = Start-Process -FilePath (Get-WorkerPowerShellPath) -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath -PassThru
    return [pscustomobject]@{ RunId = $runId; Process = $process; InputPath = $inputPath; OutputPath = $outputPath; ErrorPath = $errorPath; ReadOffset = 0; DoneEvent = $false }
}

function Start-WorkflowJob {
    param($Workflow, [switch]$Manual)
    if ($null -eq $Workflow) { return }
    $workflowId = [string]$Workflow.Id
    if ($script:RunningJobs.ContainsKey($workflowId)) {
        Write-WorkflowLog ('任务：' + $Workflow.Name + '正在运行，已跳过重复启动。') 'WARN'
        return
    }
    try {
        $worker = Start-WorkerProcess $Workflow
        $record = [pscustomobject]@{
            Worker = $worker
            WorkflowId = $workflowId
            WorkflowName = [string]$Workflow.Name
            Manual = [bool]$Manual
            DoneEvent = $false
            StartedAt = Get-Date
            Status = '运行中'
            CurrentNodeId = ''
            CurrentNodeName = '等待节点事件'
            CurrentNodeType = ''
            ActiveProcessId = 0
            ActiveCodexSessionId = ''
            NodeStack = New-Object System.Collections.ArrayList
            Logs = New-Object System.Collections.ArrayList
            StopRequested = $false
        }
        Add-RunningTaskLog $record '任务已启动。' 'INFO' 'Lifecycle'
        $script:RunningJobs[$workflowId] = $record
        Write-WorkflowLog "已启动任务：$($Workflow.Name)"
        if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = "运行中：$($Workflow.Name)" }
        Refresh-RunningTasksView
    } catch {
        Write-WorkflowLog "启动任务失败：$($_.Exception.Message)" 'ERROR'
    }
}

function Stop-WorkflowJob {
    param([string]$WorkflowId, [switch]$Silent)
    if ([string]::IsNullOrWhiteSpace($WorkflowId) -or -not $script:RunningJobs.ContainsKey($WorkflowId)) { return $false }
    $record = $script:RunningJobs[$WorkflowId]
    if ($record.StopRequested) { return $true }
    $record.StopRequested = $true
    $record.Status = '正在停止'
    Add-RunningTaskLog $record '收到停止请求，正在终止任务及其子进程。' 'WARN' 'Lifecycle'
    if (-not $Silent) { Write-WorkflowLog "$($record.WorkflowName)：正在停止任务" 'WARN' }
    try {
        if (-not $record.Worker.Process.HasExited) { Stop-WorkflowProcessTree ([int]$record.Worker.Process.Id) }
    } catch {
        Add-RunningTaskLog $record ('停止任务失败：' + $_.Exception.Message) 'ERROR' 'Lifecycle'
        if (-not $Silent) { Write-WorkflowLog "$($record.WorkflowName)：停止任务失败：$($_.Exception.Message)" 'ERROR' }
        return $false
    }
    Refresh-RunningTasksView
    return $true
}

function Restart-WorkflowJob {
    param([string]$WorkflowId)
    if ([string]::IsNullOrWhiteSpace($WorkflowId)) { return $false }
    $workflow = Find-WorkflowById $WorkflowId
    if ($null -eq $workflow) { return $false }
    if ($script:RunningJobs.ContainsKey($WorkflowId)) {
        $script:PendingWorkflowRestarts[$WorkflowId] = $true
        $stopped = Stop-WorkflowJob $WorkflowId
        if (-not $stopped) { [void]$script:PendingWorkflowRestarts.Remove($WorkflowId) }
        return $stopped
    }
    [void]$script:PendingWorkflowRestarts.Remove($WorkflowId)
    Start-WorkflowJob $workflow -Manual
    return $true
}

function ConvertTo-ScheduleTimeSpan {
    param([string]$Text, [switch]$ThrowOnInvalid)
    $parsed = [datetime]::MinValue
    $formats = [string[]]@('HH:mm:ss','H:mm:ss','HH:mm','H:mm')
    $valid = [datetime]::TryParseExact($Text, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $valid) {
        if ($ThrowOnInvalid) { throw '时间必须使用 HH:mm:ss 格式，例如 09:30:00。' }
        return [timespan]::FromHours(9)
    }
    return $parsed.TimeOfDay
}

function Get-ScheduleWeekdays {
    param([string]$Text, [switch]$ThrowOnInvalid)
    $days = New-Object System.Collections.ArrayList
    foreach ($part in @($Text -split '[,，;；\s]+')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $day = 0
        if (-not [int]::TryParse($part, [ref]$day) -or $day -lt 1 -or $day -gt 7) {
            if ($ThrowOnInvalid) { throw '每周日期使用 1-7，周一为 1、周日为 7，可用逗号分隔。' }
            continue
        }
        if (-not $days.Contains($day)) { [void]$days.Add($day) }
    }
    if ($days.Count -eq 0) {
        if ($ThrowOnInvalid) { throw '每周执行至少需要选择一天。' }
        [void]$days.Add(1)
    }
    return @($days | Sort-Object)
}

function Get-NextWorkflowRunUtc {
    param($Workflow, [datetime]$AfterUtc = ([datetime]::UtcNow), [switch]$Validate)
    if ($AfterUtc.Kind -ne [DateTimeKind]::Utc) { $AfterUtc = $AfterUtc.ToUniversalTime() }
    $kind = [string](Get-UiConfigValue $Workflow 'ScheduleKind' 'Interval')
    $minutes = [Math]::Max(1, [int](Get-UiConfigValue $Workflow 'IntervalMinutes' 60))
    if ($kind -eq 'Interval') { return $AfterUtc.AddMinutes($minutes) }

    $time = ConvertTo-ScheduleTimeSpan ([string](Get-UiConfigValue $Workflow 'ScheduleTime' '09:00:00')) -ThrowOnInvalid:$Validate
    $afterLocal = $AfterUtc.ToLocalTime()
    if ($kind -eq 'Daily' -or $kind -eq 'NextTime') {
        $candidate = $afterLocal.Date.Add($time)
        if ($candidate -le $afterLocal) { $candidate = $candidate.AddDays(1) }
        return $candidate.ToUniversalTime()
    }
    if ($kind -eq 'Weekly') {
        $weekdays = @(Get-ScheduleWeekdays ([string](Get-UiConfigValue $Workflow 'ScheduleWeekdays' '1')) -ThrowOnInvalid:$Validate)
        for ($offset = 0; $offset -le 7; $offset++) {
            $candidate = $afterLocal.Date.AddDays($offset).Add($time)
            $weekday = if ($candidate.DayOfWeek -eq [DayOfWeek]::Sunday) { 7 } else { [int]$candidate.DayOfWeek }
            if ($weekdays -contains $weekday -and $candidate -gt $afterLocal) { return $candidate.ToUniversalTime() }
        }
    }
    if ($kind -eq 'Monthly') {
        $requestedDay = [Math]::Min(31, [Math]::Max(1, [int](Get-UiConfigValue $Workflow 'ScheduleDayOfMonth' 1)))
        for ($offset = 0; $offset -le 13; $offset++) {
            $month = $afterLocal.Date.AddDays(1 - $afterLocal.Day).AddMonths($offset)
            $day = [Math]::Min($requestedDay, [DateTime]::DaysInMonth($month.Year, $month.Month))
            $candidate = New-Object DateTime($month.Year, $month.Month, $day, $time.Hours, $time.Minutes, $time.Seconds, [DateTimeKind]::Local)
            if ($candidate -gt $afterLocal) { return $candidate.ToUniversalTime() }
        }
    }
    if ($Validate) { throw '无法计算下一次执行时间。' }
    return $AfterUtc.AddMinutes($minutes)
}

function Complete-WorkflowSchedule {
    param($Workflow)
    if ([string](Get-UiConfigValue $Workflow 'ScheduleMode' 'Loop') -eq 'Once') {
        $Workflow.Enabled = $false
        $Workflow.NextRunUtc = ''
        if ($null -ne $script:CurrentWorkflow -and [string]$script:CurrentWorkflow.Id -eq [string]$Workflow.Id -and $null -ne $script:WorkflowEnabled) {
            $script:BindingWorkflow = $true
            $script:WorkflowEnabled.Checked = $false
            $script:BindingWorkflow = $false
        }
    } else {
        $Workflow.NextRunUtc = (Get-NextWorkflowRunUtc $Workflow ([datetime]::UtcNow)).ToString('o')
    }
}

function Get-BalloonLaunchSpec {
    param([string]$ClickAction, [string]$ClickTarget)
    $action = if ([string]::IsNullOrWhiteSpace($ClickAction)) { 'None' } else { $ClickAction.Trim() }
    if ($action -eq 'None') { return $null }
    $target = Resolve-ConfiguredPath $ClickTarget
    if ([string]::IsNullOrWhiteSpace($target)) { throw '气泡点击目标为空。' }
    if ($action -eq 'OpenPath') {
        if (-not [IO.File]::Exists($target) -and -not [IO.Directory]::Exists($target)) { throw ('气泡点击路径不存在：' + $target) }
        return [pscustomobject]@{ FilePath=$target; Arguments=@(); WorkingDirectory='' }
    }
    if ($action -eq 'OpenUrl') {
        $uri = $null
        if (-not [Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https')) { throw '气泡点击 URL 必须是 http 或 https 绝对地址。' }
        return [pscustomobject]@{ FilePath=$uri.AbsoluteUri; Arguments=@(); WorkingDirectory='' }
    }
    throw ('不支持的气泡点击行为：' + $action)
}

function Invoke-WorkflowBalloonAction {
    $actionRecord = $script:PendingBalloonAction
    $script:PendingBalloonAction = $null
    if ($null -eq $actionRecord) { return $false }
    try {
        $launch = Get-BalloonLaunchSpec ([string]$actionRecord.ClickAction) ([string]$actionRecord.ClickTarget)
        if ($null -eq $launch) { return $false }
        $arguments = @($launch.Arguments)
        if ($arguments.Count -gt 0) { Start-Process -FilePath $launch.FilePath -ArgumentList $arguments | Out-Null }
        else { Start-Process -FilePath $launch.FilePath | Out-Null }
        return $true
    } catch {
        Write-WorkflowLog ('气泡点击动作失败：' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Show-WorkflowBalloon {
    param(
        [string]$Title,
        [string]$Message,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info,
        [string]$ClickAction = 'None',
        [string]$ClickTarget = ''
    )
    if ($null -eq $script:NotifyIcon) { return }
    if ([string]::IsNullOrWhiteSpace($ClickAction) -or $ClickAction -eq 'None') { $script:PendingBalloonAction = $null }
    else { $script:PendingBalloonAction = [pscustomobject]@{ ClickAction=$ClickAction; ClickTarget=$ClickTarget } }
    $script:NotifyIcon.BalloonTipTitle = if ([string]::IsNullOrWhiteSpace($Title)) { $script:AppName } else { $Title }
    $script:NotifyIcon.BalloonTipText = $Message
    $script:NotifyIcon.BalloonTipIcon = $Icon
    $script:NotifyIcon.ShowBalloonTip(5000)
}

function Register-WorkflowTrayIcon {
    param([switch]$Refresh)
    if ($null -eq $script:NotifyIcon) { return }
    try {
        if ($Refresh -and $script:NotifyIcon.Visible) { $script:NotifyIcon.Visible = $false }
        $script:NotifyIcon.Icon = Get-TrayIcon
        $script:NotifyIcon.Visible = $true
    } catch {
        Write-WorkflowLog ('托盘图标注册失败：' + $_.Exception.Message) 'ERROR'
    }
}

function Hide-WorkflowManagerToTray {
    if ($null -eq $script:MainForm -or $script:MainForm.IsDisposed) { return }
    $script:MainForm.Hide()
    Register-WorkflowTrayIcon
}

function Restore-WorkflowManagerFromTray {
    if ($null -eq $script:MainForm -or $script:MainForm.IsDisposed) { return }
    Register-WorkflowTrayIcon
    $script:MainForm.WindowState = [Windows.Forms.FormWindowState]::Normal
    $script:MainForm.Show()
    $script:MainForm.Activate()
}

function Initialize-SingleInstance {
    try {
        $script:SingleInstanceCoordinator = New-Object WorkflowSingleInstanceCoordinator('Local\PowerUI.WorkflowManager.Singleton', 'Local\PowerUI.WorkflowManager.Activate')
        if (-not $script:SingleInstanceCoordinator.IsPrimary) {
            $script:SingleInstanceCoordinator.Dispose()
            $script:SingleInstanceCoordinator = $null
            return $false
        }
        return $true
    } catch {
        Release-SingleInstance
        return $true
    }
}

function Release-SingleInstance {
    if ($null -ne $script:SingleInstanceCoordinator) {
        $script:SingleInstanceCoordinator.Dispose()
        $script:SingleInstanceCoordinator = $null
    }
}

function Receive-SingleInstanceSignal {
    if ($null -eq $script:SingleInstanceCoordinator) { return }
    if ($script:SingleInstanceCoordinator.ConsumeActivationSignal()) { Restore-WorkflowManagerFromTray }
}

function Exit-WorkflowManager {
    if ($script:Exiting) { return }
    $script:Exiting = $true
    $script:AllowExit = $true

    try { Save-Workflows } catch { }
    try { Save-Projects } catch { }
    try { Save-GlobalSettings } catch { }
    try { Close-CommonPromptsWindow } catch { }
    try { Stop-AllWorkflowJobs } catch { }
    $script:PendingWorkflowRestarts.Clear()
    $script:PendingBalloonAction = $null
    Stop-WorkflowApiServer
    Stop-WebApiServer
    if ($null -ne $script:CodexConversationTimer) { $script:CodexConversationTimer.Stop(); $script:CodexConversationTimer.Dispose(); $script:CodexConversationTimer = $null }
    foreach ($record in @($script:CodexConversationProcesses.Values)) {
        try { if ($null -ne $record -and -not $record.Process.HasExited) { $record.Process.Kill() } } catch { }
        try { Dispose-CodexConversationOutputCapture $record } catch { }
        try { if ($null -ne $record) { $record.Process.Dispose() } } catch { }
    }
    $script:CodexConversationProcesses.Clear()
    $script:CodexConversationProcess = $null

    if ($null -ne $script:StartupTimer) {
        $script:StartupTimer.Stop()
        $script:StartupTimer.Dispose()
        $script:StartupTimer = $null
    }
    if ($null -ne $script:SchedulerTimer) {
        $script:SchedulerTimer.Stop()
        $script:SchedulerTimer.Dispose()
        $script:SchedulerTimer = $null
    }
    if ($null -ne $script:JobPollTimer) {
        $script:JobPollTimer.Stop()
        $script:JobPollTimer.Dispose()
        $script:JobPollTimer = $null
    }
    if ($null -ne $script:MemoryMaintenanceTimer) {
        $script:MemoryMaintenanceTimer.Stop()
        $script:MemoryMaintenanceTimer.Dispose()
        $script:MemoryMaintenanceTimer = $null
    }
    try { Cancel-CodexConversationFileTreeRequests } catch { }
    try { Reset-CodexConversationOutput } catch { }
    if ($null -ne $script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.ContextMenuStrip = $null
        $script:NotifyIcon.Dispose()
        $script:NotifyIcon = $null
    }
    if ($null -ne $script:TrayIcon) {
        try { $script:TrayIcon.Dispose() } catch { }
        $script:TrayIcon = $null
        $script:TrayIconSize = 0
    }
    if ($null -ne $script:TrayMenu) {
        $script:TrayMenu.Dispose()
        $script:TrayMenu = $null
        $script:TrayOpenItem = $null
        $script:TrayRunItem = $null
        $script:TrayRunAllItem = $null
        $script:TrayExitItem = $null
    }
    if ($null -ne $script:CanvasContextMenu) {
        $script:CanvasContextMenu.Dispose()
        $script:CanvasContextMenu = $null
    }
    if ($null -ne $script:WorkflowListContextMenu) {
        $script:WorkflowListContextMenu.Dispose()
        $script:WorkflowListContextMenu = $null
    }
    if ($null -ne $script:CodexConversationLinkContextMenu) {
        $script:CodexConversationLinkContextMenu.Dispose()
        $script:CodexConversationLinkContextMenu = $null
        $script:CodexConversationLinkContext = $null
    }
    if ($null -ne $script:MainForm -and -not $script:MainForm.IsDisposed) {
        if ($script:MainForm -is [WorkflowMainForm]) { $script:MainForm.AllowApplicationExit = $true }
        $script:MainForm.Close()
        $script:MainForm.Dispose()
    }
    if($null-ne$script:CodexConversationFileTreeRootFont){try{$script:CodexConversationFileTreeRootFont.Dispose()}catch{};$script:CodexConversationFileTreeRootFont=$null}
    $script:CodexConversationFileTreeCallback=$null
    $script:CodexConversationSurfaceRefreshCallback=$null
    $script:CodexConversationMouseWheelCallback=$null
    $script:CodexConversationBottomScrollCallback=$null
    $script:CodexConversationRecordScrollCallback=$null
    $script:CodexConversationSessionSwitchCallback=$null
    if ($null -ne $script:ApplicationContext) {
        $script:ApplicationContext.ExitThread()
    }
    [void](Release-SingleInstance)
    if ($null -ne $script:TrayIcon) {
        $script:TrayIcon.Dispose()
        $script:TrayIcon = $null
    }
    if ($null -ne $script:SmallApplicationIcon) {
        $script:SmallApplicationIcon.Dispose()
        $script:SmallApplicationIcon = $null
    }
    if ($null -ne $script:ApplicationIcon) {
        $script:ApplicationIcon.Dispose()
        $script:ApplicationIcon = $null
    }
}

function Poll-WorkflowJobs {
    $workflowIds=@($script:RunningJobs.Keys)
    $remainingEventBudget=240
    $remainingWorkflowCount=$workflowIds.Count
    foreach ($workflowId in $workflowIds) {
        $record = $script:RunningJobs[$workflowId]
        if($null-eq$record){$remainingWorkflowCount--;continue}
        $workflow = Find-WorkflowById $workflowId
        $workflowName = if ($null -ne $workflow) { [string]$workflow.Name } else { [string]$record.WorkflowName }
        $output = @()
        $outputReadFailed = $false
        try {
            $maxLinesForWorkflow=if($remainingEventBudget-gt0){[Math]::Max(1,[Math]::Floor($remainingEventBudget/[Math]::Max(1,$remainingWorkflowCount)))}else{0}
            if($maxLinesForWorkflow-gt0){$output=@(Read-WorkerEventLines $record.Worker 131072 $maxLinesForWorkflow);$remainingEventBudget=[Math]::Max(0,$remainingEventBudget-$output.Count)}
        } catch { $outputReadFailed = $true }
        $remainingWorkflowCount--
        $commandLogBatch=New-Object System.Collections.Generic.List[object]
        foreach ($line in $output) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            try { $event = [string]$line | ConvertFrom-Json } catch { Add-RunningTaskLog $record ([string]$line) 'DEBUG' 'Raw'; Write-WorkflowLog ([string]$line) 'DEBUG'; continue }
            $eventAt = [string]$event.At
            switch ([string]$event.Kind) {
                'NodeStart' {
                    $nodeState=[pscustomobject]@{Id=[string]$event.Data.NodeId;Name=[string]$event.Data.NodeName;Type=[string]$event.Data.NodeType}
                    [void]$record.NodeStack.Add($nodeState)
                    $record.CurrentNodeId=$nodeState.Id; $record.CurrentNodeName=$nodeState.Name; $record.CurrentNodeType=$nodeState.Type
                    Add-RunningTaskLog $record ("进入节点：$($nodeState.Name) [$($nodeState.Type)]") 'INFO' 'NodeStart' $eventAt
                }
                'NodeComplete' {
                    $completedId=[string]$event.Data.NodeId
                    for($index=$record.NodeStack.Count-1;$index-ge0;$index--){if([string]$record.NodeStack[$index].Id-eq$completedId){$record.NodeStack.RemoveAt($index);break}}
                    if($record.NodeStack.Count-gt0){$current=$record.NodeStack[$record.NodeStack.Count-1];$record.CurrentNodeId=[string]$current.Id;$record.CurrentNodeName=[string]$current.Name;$record.CurrentNodeType=[string]$current.Type}else{$record.CurrentNodeId='';$record.CurrentNodeName='等待后续节点';$record.CurrentNodeType=''}
                    if([string]$event.Data.NodeType-in@('Cmd','Python')){$record.ActiveProcessId=0}
                    if([string]$event.Data.NodeType-eq'Codex'){$record.ActiveProcessId=0;$record.ActiveCodexSessionId='';Update-CodexConversationControls}
                    Add-RunningTaskLog $record ("完成节点：$([string]$event.Data.NodeName)") 'INFO' 'NodeComplete' $eventAt
                }
                'CommandOutput' {
                    $streamName=[string]$event.Data.Stream
                    $level=if($streamName-eq'stderr'){'ERROR'}else{'INFO'}
                    $message='['+$streamName+'] '+[string]$event.Message
                    Add-RunningTaskLog $record $message $level 'CommandOutput' $eventAt
                    $commandLogBatch.Add([pscustomobject]@{At=$eventAt;Level=$level;Message="$workflowName：$([string]$event.Data.NodeName) $message"})
                }
                'CommandStarted' {
                    $record.ActiveProcessId=[int]$event.Data.ProcessId
                    $processKind=[string](Get-UiConfigValue $event.Data 'ProcessKind' 'CMD')
                    if([string]::IsNullOrWhiteSpace($processKind)){$processKind='CMD'}
                    Add-RunningTaskLog $record ("$processKind 进程已启动，PID：$([string]$event.Data.ProcessId)") 'INFO' 'CommandStarted' $eventAt
                }
                'CodexStarted' {
                    $record.ActiveProcessId=[int]$event.Data.ProcessId
                    $record.ActiveCodexSessionId=[string]$event.Data.SessionId
                    $modelText=if([string]::IsNullOrWhiteSpace([string]$event.Data.Model)){''}else{'，模型：'+[string]$event.Data.Model}
                    Add-RunningTaskLog $record ("Codex 进程已启动，PID：$([string]$event.Data.ProcessId)，会话：$([string]$event.Data.SessionId)$modelText") 'INFO' 'CodexStarted' $eventAt
                    Update-CodexConversationControls
                }
                'Log' { Add-RunningTaskLog $record ([string]$event.Message) 'INFO' 'Log' $eventAt; Write-WorkflowLog "$workflowName：$($event.Message)" }
                'Balloon' { Add-RunningTaskLog $record ('气泡提醒：'+[string]$event.Message) 'INFO' 'Balloon' $eventAt; Show-WorkflowBalloon ([string]$event.Data.Title) ([string]$event.Message) ([Windows.Forms.ToolTipIcon]::Info) ([string]$event.Data.ClickAction) ([string]$event.Data.ClickTarget) }
                'Error' { $record.Status='执行失败'; Add-RunningTaskLog $record ([string]$event.Message) 'ERROR' 'Error' $eventAt; Write-WorkflowLog "$workflowName：$($event.Message)" 'ERROR'; Show-WorkflowBalloon '工作流执行失败' "$workflowName：$($event.Message)" ([Windows.Forms.ToolTipIcon]::Error) }
                'Done' { $record.DoneEvent = $true; $record.Status='执行完成'; Add-RunningTaskLog $record '执行完成。' 'INFO' 'Done' $eventAt; Write-WorkflowLog "$workflowName：执行完成" }
            }
        }
        if($commandLogBatch.Count-gt0){Write-WorkflowLogBatch $commandLogBatch.ToArray()}
        if ($record.Worker.Process.HasExited) {
            if ($outputReadFailed) { continue }
            if(-not(Test-WorkerEventOutputDrained $record.Worker)){continue}
            if (Test-Path -LiteralPath $record.Worker.ErrorPath) {
                $errorText = (Read-TextFileWithRetry $record.Worker.ErrorPath 1000).Trim()
                if (-not [string]::IsNullOrWhiteSpace($errorText)) { Add-RunningTaskLog $record $errorText 'ERROR' 'WorkerError'; Write-WorkflowLog "$workflowName：$errorText" 'ERROR' }
            }
            $restartRequested = $script:PendingWorkflowRestarts.ContainsKey($workflowId)
            $record.ActiveProcessId=0; $record.ActiveCodexSessionId=''; Update-CodexConversationControls
            if($record.StopRequested){$record.Status='已停止';Add-RunningTaskLog $record '任务已停止。' 'WARN' 'Stopped';Write-WorkflowLog "$workflowName：任务已停止" 'WARN'}
            elseif(-not$record.DoneEvent-and$record.Status-ne'执行失败'){$record.Status='异常结束';Add-RunningTaskLog $record ('任务进程异常结束，退出码：'+[string]$record.Worker.Process.ExitCode) 'ERROR' 'WorkerExit';Write-WorkflowLog "$workflowName：任务进程异常结束，退出码 $($record.Worker.Process.ExitCode)" 'ERROR'}
            if ($null -ne $workflow -and -not $record.Manual) {
                Complete-WorkflowSchedule $workflow
            }
            Refresh-RunningTasksView
            foreach ($path in @($record.Worker.InputPath, $record.Worker.OutputPath, $record.Worker.ErrorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            try { $record.Worker.Process.Dispose() } catch { }
            $script:RunningJobs.Remove($workflowId)
            if ($restartRequested) {
                [void]$script:PendingWorkflowRestarts.Remove($workflowId)
                $restartWorkflow = Find-WorkflowById $workflowId
                if ($null -ne $restartWorkflow -and -not $script:Exiting) { Start-WorkflowJob $restartWorkflow -Manual }
            }
            Save-Workflows
            if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '后台调度运行中' }
            Update-WorkflowNextRunLabel
        }
    }
    Refresh-RunningTasksView
}

function Invoke-SchedulerTick {
    Receive-SingleInstanceSignal
    Invoke-PendingWorkflowApiRequests
    $now = (Get-Date).ToUniversalTime()
    foreach ($workflow in @($script:Workflows)) {
        if (-not [bool]$workflow.Enabled) { continue }
        if ($script:RunningJobs.ContainsKey([string]$workflow.Id)) { continue }
        try { $next = [datetime]$workflow.NextRunUtc } catch { $next = $now }
        if ($next.ToUniversalTime() -le $now) { Start-WorkflowJob $workflow }
    }
}

function Stop-AllWorkflowJobs {
    $script:PendingWorkflowRestarts.Clear()
    foreach ($workflowId in @($script:RunningJobs.Keys)) {
        [void](Stop-WorkflowJob $workflowId -Silent)
        $record=$script:RunningJobs[$workflowId]
        foreach ($path in @($record.Worker.InputPath, $record.Worker.OutputPath, $record.Worker.ErrorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        try { $record.Worker.Process.Dispose() } catch { }
    }
    $script:RunningJobs.Clear()
    Update-CodexConversationControls
    Refresh-RunningTasksView
}

function Update-WorkflowNextRunLabel {
    if ($null -eq $script:NextRunLabel) { return }
    if ($null -eq $script:CurrentWorkflow) { $script:NextRunLabel.Text = ''; return }
    if (-not [bool]$script:CurrentWorkflow.Enabled) { $script:NextRunLabel.Text = '未启用定时'; return }
    try { $local = ([datetime]$script:CurrentWorkflow.NextRunUtc).ToLocalTime(); $script:NextRunLabel.Text = '下次：' + $local.ToString('yyyy-MM-dd HH:mm:ss') }
    catch { $script:NextRunLabel.Text = '等待调度' }
}

function Update-ProjectInfo {
    if ($null -eq $script:ProjectInfoLabel -or $null -eq $script:ProjectSessionLabel) { return }
    $hasProject = $null -ne $script:CurrentProject
    $hasProjectDirectory = $hasProject -and -not [string]::IsNullOrWhiteSpace([string]$script:CurrentProject.DefaultWorkingDirectory)
    $projectSessions=if($hasProject){@(Get-ProjectCodexSessions $script:CurrentProject)}else{@()};$projectSessions=@($projectSessions)
    $primarySession=if($projectSessions.Count-gt0){$projectSessions[0]}else{$null}
    $hasProjectSession = $null -ne $primarySession
    if ($null -ne $script:ProjectEditButton) { $script:ProjectEditButton.Enabled = $hasProject }
    if ($null -ne $script:ProjectDeleteButton) { $script:ProjectDeleteButton.Enabled = $hasProject }
    if ($null -ne $script:ProjectOpenButton) { $script:ProjectOpenButton.Enabled = $hasProjectDirectory }
    if ($null -ne $script:ProjectVSCodeButton) { $script:ProjectVSCodeButton.Enabled = $hasProjectDirectory }
    if ($null -ne $script:ProjectChatButton) { $script:ProjectChatButton.Enabled = $hasProjectDirectory }
    if ($null -ne $script:ProjectTerminalButton) { $script:ProjectTerminalButton.Enabled = $hasProjectSession }
    if ($null -eq $script:CurrentProject) {
        $script:ProjectInfoLabel.Text = '未分组的工作任务'
        $script:ProjectSessionLabel.Text = '无项目默认目录或 Codex 会话'
        if ($null -ne $script:ProjectToolTip) { $script:ProjectToolTip.SetToolTip($script:ProjectInfoLabel, '未分组的工作任务'); $script:ProjectToolTip.SetToolTip($script:ProjectSessionLabel, '无项目默认目录或 Codex 会话') }
        return
    }
    $directory = [string]$script:CurrentProject.DefaultWorkingDirectory
    $script:ProjectInfoLabel.Text = '目录：' + $directory
    if($null-eq$primarySession){
        $sessionText='Codex：未关联会话'
        $sessionTip='未关联会话'
    }else{
        $sessionText='Codex：'+$projectSessions.Count+' 个会话 · 主会话：'+[string]$primarySession.Description
        if(-not[string]::IsNullOrWhiteSpace([string]$primarySession.CodexModel)){$sessionText+=' · 模型：'+[string]$primarySession.CodexModel}
        $sessionTip=($projectSessions|ForEach-Object{[string]$_.Description+'：'+[string]$_.SessionId+$(if([string]::IsNullOrWhiteSpace([string]$_.CodexModel)){''}else{"`r`n模型：$([string]$_.CodexModel)"})})-join"`r`n`r`n"
    }
    $script:ProjectSessionLabel.Text=$sessionText
    if ($null -ne $script:ProjectToolTip) { $script:ProjectToolTip.SetToolTip($script:ProjectInfoLabel, $directory); $script:ProjectToolTip.SetToolTip($script:ProjectSessionLabel, $sessionTip) }
}

function Refresh-ProjectSelector {
    if ($null -eq $script:ProjectSelector -or $script:ProjectSelector.IsDisposed -or $script:ProjectSelectorRefreshActive) { return }
    $selectedId = Get-CurrentProjectId
    $script:ProjectSelectorRefreshActive=$true
    try{
        $script:ProjectSelector.BeginUpdate(); $script:ProjectSelector.Items.Clear()
        [void]$script:ProjectSelector.Items.Add([pscustomobject]@{ Id=''; Name='无项目'; Project=$null })
        foreach($project in @($script:Projects | Sort-Object @{Expression={try{[datetime]$_.UpdatedAt}catch{[datetime]::MinValue}};Descending=$true}, @{Expression={$_.Name};Descending=$false})){ [void]$script:ProjectSelector.Items.Add([pscustomobject]@{ Id=[string]$project.Id; Name=[string]$project.Name; Project=$project }) }
        $itemHeight=[Math]::Max(24,[int]$script:ProjectSelector.ItemHeight)
        $script:ProjectSelector.DropDownHeight=[Math]::Min(360,[Math]::Max($itemHeight+4,($script:ProjectSelector.Items.Count*$itemHeight)+2))
        $script:ProjectSelector.IntegralHeight=$true
        $script:ProjectSelector.DropDownWidth=[Math]::Max(300,$script:ProjectSelector.Width)
        $index=0
        for($i=0;$i -lt $script:ProjectSelector.Items.Count;$i++){ $item=Get-UiIndexedItemSafe $script:ProjectSelector.Items $i; if($null-ne$item-and[string]$item.Id -eq $selectedId){$index=$i;break} }
        if($script:ProjectSelector.Items.Count -gt 0){$script:ProjectSelector.SelectedIndex=[Math]::Max(0,[Math]::Min($index,$script:ProjectSelector.Items.Count-1))}
        $item=$script:ProjectSelector.SelectedItem; $script:CurrentProject=if($null -ne $item){$item.Project}else{$null}
    }finally{
        try{$script:ProjectSelector.EndUpdate()}catch{}
        $script:ProjectSelectorRefreshActive=$false
    }
    Update-ProjectInfo; Refresh-WorkflowList
}

function Bind-CurrentProject {
    if($null -eq $script:ProjectSelector -or $script:ProjectSelector.SelectedIndex -lt 0 -or $script:ProjectSelectorRefreshActive){return}
    $item=$script:ProjectSelector.SelectedItem
    $script:CurrentProject=if($null -ne $item){$item.Project}else{$null}
    $script:CurrentWorkflow=$null
    Update-ProjectInfo
    Show-WorkflowWorkspace
    Refresh-WorkflowList
}

function Refresh-WorkflowList {
    if ($null -eq $script:WorkflowList) { return }
    $selectedId = if ($null -ne $script:CurrentWorkflow) { [string]$script:CurrentWorkflow.Id } else { '' }
    $script:WorkflowList.BeginUpdate()
    $script:WorkflowList.Items.Clear()
    $projectId = Get-CurrentProjectId
    foreach ($workflow in @($script:Workflows | Where-Object { [string](Get-UiConfigValue $_ 'ProjectId' '') -eq $projectId })) { [void]$script:WorkflowList.Items.Add($workflow) }
    $script:WorkflowList.EndUpdate()
    $index = -1
    for ($i = 0; $i -lt $script:WorkflowList.Items.Count; $i++) { if ([string]$script:WorkflowList.Items[$i].Id -eq $selectedId) { $index = $i; break } }
    if ($index -ge 0) { $script:WorkflowList.SelectedIndex = $index }
    elseif ($script:WorkflowList.Items.Count -gt 0) { $script:WorkflowList.SelectedIndex = 0 }
    else {
        $script:CurrentWorkflow = $null
        if ($null -ne $script:WorkflowNameBox) { $script:WorkflowNameBox.Text = '' }
        if ($null -ne $script:Canvas) { $script:SelectedNode=$null; $script:SelectedEdge=$null; $script:Canvas.Invalidate() }
        Update-WorkflowNextRunLabel
    }
}

function Remove-SelectedWorkflowTask {
    param([switch]$SkipConfirmation)
    $workflow = if ($null -ne $script:WorkflowList -and $script:WorkflowList.SelectedIndex -ge 0) { $script:WorkflowList.SelectedItem } else { $script:CurrentWorkflow }
    if ($null -eq $workflow) { return $false }
    $workflowId = [string]$workflow.Id
    if ([string]::IsNullOrWhiteSpace($workflowId)) { return $false }
    if (@($script:Workflows).Count -le 1) {
        [void][Windows.Forms.MessageBox]::Show('至少需要保留一个工作任务。', '无法删除', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
        return $false
    }
    if ($script:RunningJobs.ContainsKey($workflowId)) {
        [void][Windows.Forms.MessageBox]::Show('任务正在运行，请先停止任务后再删除。', '无法删除', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }
    if (-not $SkipConfirmation) {
        $answer = [Windows.Forms.MessageBox]::Show(('删除任务“' + [string]$workflow.Name + '”？'), '删除任务', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return $false }
    }
    $script:Workflows = @($script:Workflows | Where-Object { [string]$_.Id -ne $workflowId })
    Save-Workflows
    if ($null -ne $script:CurrentWorkflow -and [string]$script:CurrentWorkflow.Id -eq $workflowId) { $script:CurrentWorkflow = $null }
    Refresh-WorkflowList
    return $true
}

function Get-CodexConversationHistoryKey {
    param([string]$Mode='Project',[string]$ProjectId='',[string]$SessionId='')
    if($Mode-eq'WorkflowAi'){return 'WorkflowAi'}
    $sessionKey=if([string]::IsNullOrWhiteSpace($SessionId)){'_new'}else{$SessionId}
    return 'Project:'+[string]$ProjectId+':'+$sessionKey
}

function Limit-CodexConversationHistoryText {
    param([AllowEmptyString()][string]$Text, [int]$Maximum = 1500000)
    if ($null -eq $Text) { return '' }
    if ($Maximum -lt 1000 -or $Text.Length -le $Maximum) { return $Text }
    $tailLength = [Math]::Max(1000, $Maximum - 96)
    return "[历史缓存已裁剪，仅保留末尾内容]`r`n" + $Text.Substring([Math]::Max(0, $Text.Length - $tailLength))
}

function Get-CodexConversationSnapshotCharacterCount {
    param($Snapshot)
    if ($null -eq $Snapshot) { return 0 }
    $total = 0
    foreach ($message in @((Get-UiConfigValue $Snapshot 'Messages' @()))) {
        $total += ([string](Get-UiConfigValue $message 'Text' '')).Length
    }
    foreach ($message in @((Get-UiConfigValue $Snapshot 'PendingMessages' @()))) {
        $total += ([string](Get-UiConfigValue $message 'Text' '')).Length
    }
    return $total
}

function Get-CodexConversationProtectedSessionIds {
    $protected = @{}
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CodexConversationSessionId)) {
        $protected[[string]$script:CodexConversationSessionId] = $true
    }
    foreach ($record in @($script:CodexConversationProcesses.Values)) {
        if ($null -eq $record) { continue }
        foreach ($name in @('SessionId','InitialSessionId')) {
            $sessionId = [string](Get-UiConfigValue $record $name '')
            if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $protected[$sessionId] = $true }
        }
    }
    return $protected
}

function Limit-CodexConversationMessageText {
    param([AllowEmptyString()][string]$Text, [int]$Maximum = 2000000)
    if ($null -eq $Text -or $Maximum -lt 1000 -or $Text.Length -le $Maximum) { return [string]$Text }
    $tailLength = [Math]::Max(1000, $Maximum - 96)
    return "[消息过长，已裁剪，仅保留末尾内容]`r`n" + $Text.Substring([Math]::Max(0, $Text.Length - $tailLength))
}

function Trim-CodexConversationMessageLists {
    param($Messages, $Pending, [int]$MaximumCharacters = 4000000)
    if ($null -eq $Messages -or $null -eq $Pending) { return }
    $total = 0
    foreach ($item in @($Messages)) { $total += ([string](Get-UiConfigValue $item 'Text' '')).Length }
    foreach ($item in @($Pending)) { $total += ([string](Get-UiConfigValue $item 'Text' '')).Length }
    while ($total -gt $MaximumCharacters -and $Messages.Count -gt 1) {
        $first = $Messages[0]
        $total -= ([string](Get-UiConfigValue $first 'Text' '')).Length
        $Messages.RemoveAt(0)
    }
    while ($total -gt $MaximumCharacters -and $Pending.Count -gt 0) {
        $first = $Pending[0]
        $total -= ([string](Get-UiConfigValue $first 'Text' '')).Length
        $Pending.RemoveAt(0)
    }
}

function Set-CodexConversationHistoryCache {
    param([string]$Key, [AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    $script:CodexConversationHistory[$Key] = Limit-CodexConversationHistoryText $Text $script:CodexConversationHistoryMaxEntryCharacters
    $script:CodexConversationHistoryAccess[$Key] = Get-Date
    if ($script:CodexConversationHistory.Count -gt $script:CodexConversationHistoryMaxCount) {
        Invoke-WorkflowMemoryMaintenance -Force
    }
}

function Set-CodexConversationSnapshotCache {
    param([string]$SessionId, $Snapshot)
    if ([string]::IsNullOrWhiteSpace($SessionId) -or $null -eq $Snapshot) { return }
    $script:CodexConversationSnapshots[$SessionId] = $Snapshot
    $script:CodexConversationSnapshotAccess[$SessionId] = Get-Date
    if ($script:CodexConversationSnapshots.Count -gt $script:CodexConversationSnapshotMaxCount) {
        Invoke-WorkflowMemoryMaintenance -Force
    }
}

function Invoke-WorkflowMemoryMaintenance {
    param([switch]$Force)
    if (-not $Force -and $null -ne $script:LastMemoryMaintenanceAt -and ((Get-Date) - $script:LastMemoryMaintenanceAt).TotalSeconds -lt 45) { return }
    $script:LastMemoryMaintenanceAt = Get-Date

    $protected = Get-CodexConversationProtectedSessionIds
    $snapshotKeys = @($script:CodexConversationSnapshots.Keys)
    foreach ($key in $snapshotKeys) {
        if (-not $script:CodexConversationSnapshotAccess.ContainsKey($key)) { $script:CodexConversationSnapshotAccess[$key] = Get-Date }
    }
    $snapshotTotal = 0
    foreach ($key in @($script:CodexConversationSnapshots.Keys)) { $snapshotTotal += Get-CodexConversationSnapshotCharacterCount $script:CodexConversationSnapshots[$key] }
    $orderedSnapshots = @($script:CodexConversationSnapshots.Keys | Sort-Object {
        if ($script:CodexConversationSnapshotAccess.ContainsKey($_)) { [datetime]$script:CodexConversationSnapshotAccess[$_] } else { [datetime]::MinValue }
    })
    foreach ($key in $orderedSnapshots) {
        if (($script:CodexConversationSnapshots.Count -le $script:CodexConversationSnapshotMaxCount) -and ($snapshotTotal -le $script:CodexConversationSnapshotMaxCharacters)) { break }
        if ($protected.ContainsKey([string]$key) -and $script:CodexConversationSnapshots.Count -le $script:CodexConversationSnapshotMaxCount) { continue }
        if ($script:CodexConversationSnapshots.ContainsKey($key)) {
            $snapshotTotal -= Get-CodexConversationSnapshotCharacterCount $script:CodexConversationSnapshots[$key]
            [void]$script:CodexConversationSnapshots.Remove($key)
        }
        [void]$script:CodexConversationSnapshotAccess.Remove($key)
    }
    foreach ($key in @($script:CodexConversationSnapshotAccess.Keys)) {
        if (-not $script:CodexConversationSnapshots.ContainsKey($key)) { [void]$script:CodexConversationSnapshotAccess.Remove($key) }
    }

    foreach ($key in @($script:CodexConversationHistory.Keys)) {
        if (-not $script:CodexConversationHistoryAccess.ContainsKey($key)) { $script:CodexConversationHistoryAccess[$key] = Get-Date }
    }
    $historyTotal = 0
    foreach ($value in @($script:CodexConversationHistory.Values)) { $historyTotal += ([string]$value).Length }
    $orderedHistory = @($script:CodexConversationHistory.Keys | Sort-Object {
        if ($script:CodexConversationHistoryAccess.ContainsKey($_)) { [datetime]$script:CodexConversationHistoryAccess[$_] } else { [datetime]::MinValue }
    })
    foreach ($key in $orderedHistory) {
        if (($script:CodexConversationHistory.Count -le $script:CodexConversationHistoryMaxCount) -and ($historyTotal -le $script:CodexConversationHistoryMaxCharacters)) { break }
        $value = [string]$script:CodexConversationHistory[$key]
        $historyTotal -= $value.Length
        [void]$script:CodexConversationHistory.Remove($key)
        [void]$script:CodexConversationHistoryAccess.Remove($key)
    }
    foreach ($key in @($script:CodexConversationHistoryAccess.Keys)) {
        if (-not $script:CodexConversationHistory.ContainsKey($key)) { [void]$script:CodexConversationHistoryAccess.Remove($key) }
    }

    foreach ($key in @($script:CodexConversationProcesses.Keys)) {
        if (-not $script:CodexConversationProcesses.ContainsKey($key)) { continue }
        $record = $script:CodexConversationProcesses[$key]
        if ($null -eq $record) { [void]$script:CodexConversationProcesses.Remove($key); continue }
        $state = [string](Get-UiConfigValue $record 'FinalizeState' 'Running')
        if ($state -eq 'Finalized') {
            try { Dispose-CodexConversationOutputCapture $record } catch { }
            try { $record.Process.Dispose() } catch { }
            [void]$script:CodexConversationProcesses.Remove($key)
        }
    }
    if ([string]$script:WorkflowAiConversationHistory -and $script:WorkflowAiConversationHistory.Length -gt $script:CodexConversationHistoryMaxEntryCharacters) {
        $script:WorkflowAiConversationHistory = Limit-CodexConversationHistoryText $script:WorkflowAiConversationHistory $script:CodexConversationHistoryMaxEntryCharacters
    }
}

function Format-WorkflowMemorySize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-WorkflowControlCount {
    param([Windows.Forms.Control]$Root)
    if($null-eq$Root-or$Root.IsDisposed){return 0}
    $count=0
    $stack=New-Object 'System.Collections.Generic.Stack[System.Windows.Forms.Control]'
    $stack.Push($Root)
    while($stack.Count-gt0){
        $control=$stack.Pop();$count++
        foreach($child in @($control.Controls)){if($null-ne$child-and-not$child.IsDisposed){$stack.Push($child)}}
    }
    return $count
}

function Get-WorkflowClrMemorySnapshot {
    $result = [ordered]@{ Instance = ''; Heap = $null; Gen0 = $null; Gen1 = $null; Gen2 = $null; Loh = $null; Committed = $null; GcPercent = $null }
    $processId = [Diagnostics.Process]::GetCurrentProcess().Id
    $category = $null
    try {
        $category = New-Object Diagnostics.PerformanceCounterCategory('.NET CLR Memory')
        $instance = $null
        foreach ($candidate in @($category.GetInstanceNames())) {
            $pidCounter = $null
            try {
                $pidCounter = New-Object Diagnostics.PerformanceCounter('.NET CLR Memory', 'Process ID', [string]$candidate)
                if ([int]$pidCounter.NextValue() -eq $processId) { $instance = [string]$candidate; break }
            } catch { }
            finally { if ($null -ne $pidCounter) { try { $pidCounter.Dispose() } catch { } } }
        }
        if ([string]::IsNullOrWhiteSpace($instance)) { return [pscustomobject]$result }
        $result.Instance = $instance
        $counterNames = [ordered]@{
            Heap = '# Bytes in all Heaps'
            Gen0 = 'Gen 0 heap size'
            Gen1 = 'Gen 1 heap size'
            Gen2 = 'Gen 2 heap size'
            Loh = 'Large Object Heap size'
            Committed = '# Total committed Bytes'
            GcPercent = '% Time in GC'
        }
        foreach ($name in @($counterNames.Keys)) {
            $counter = $null
            try {
                $counter = New-Object Diagnostics.PerformanceCounter('.NET CLR Memory', [string]$counterNames[$name], $instance)
                $result[$name] = [double]$counter.NextValue()
            } catch { $result[$name] = $null }
            finally { if ($null -ne $counter) { try { $counter.Dispose() } catch { } } }
        }
    } catch { }
    finally { if ($null -ne $category) { try { $category.Dispose() } catch { } } }
    return [pscustomobject]$result
}

function Get-WorkflowMemoryDiagnosticsText {
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetCurrentProcess()
        $process.Refresh()
        $snapshotCount = 0
        $snapshotCharacters = 0
        $snapshotItems = New-Object System.Collections.ArrayList
        foreach ($key in @($script:CodexConversationSnapshots.Keys)) {
            if (-not $script:CodexConversationSnapshots.ContainsKey($key)) { continue }
            $characters = Get-CodexConversationSnapshotCharacterCount $script:CodexConversationSnapshots[$key]
            $snapshotCount++
            $snapshotCharacters += $characters
            [void]$snapshotItems.Add([pscustomobject]@{ Key = [string]$key; Characters = $characters })
        }

        $historyCount = 0
        $historyCharacters = 0
        $historyItems = New-Object System.Collections.ArrayList
        foreach ($key in @($script:CodexConversationHistory.Keys)) {
            if (-not $script:CodexConversationHistory.ContainsKey($key)) { continue }
            $characters = ([string]$script:CodexConversationHistory[$key]).Length
            $historyCount++
            $historyCharacters += $characters
            [void]$historyItems.Add([pscustomobject]@{ Key = [string]$key; Characters = $characters })
        }

        $runningTaskCount = 0
        $runningLogCount = 0
        $runningLogCharacters = 0
        $runningItems = New-Object System.Collections.ArrayList
        foreach ($key in @($script:RunningJobs.Keys)) {
            if (-not $script:RunningJobs.ContainsKey($key)) { continue }
            $record = $script:RunningJobs[$key]
            if ($null -eq $record) { continue }
            $runningTaskCount++
            $taskLogCount = 0
            $taskLogCharacters = 0
            foreach ($log in @((Get-UiConfigValue $record 'Logs' @()))) {
                $message = [string](Get-UiConfigValue $log 'Message' $log)
                $taskLogCount++
                $taskLogCharacters += $message.Length
            }
            $runningLogCount += $taskLogCount
            $runningLogCharacters += $taskLogCharacters
            [void]$runningItems.Add([pscustomobject]@{ Key = [string](Get-UiConfigValue $record 'WorkflowName' $key); Characters = $taskLogCharacters; Count = $taskLogCount })
        }

        $bubbleCount = if ($null -eq $script:CodexConversationBubbleRecords) { 0 } else { [int]$script:CodexConversationBubbleRecords.Count }
        $transcriptPartCount = if ($null -eq $script:CodexConversationTranscriptParts) { 0 } else { [int]$script:CodexConversationTranscriptParts.Count }
        $pendingImageCount = if ($null -eq $script:CodexConversationPendingImages) { 0 } else { [int]$script:CodexConversationPendingImages.Count }
        $conversationProcessCount = if ($null -eq $script:CodexConversationProcesses) { 0 } else { [int]$script:CodexConversationProcesses.Count }
        $workflowAiHistoryCharacters = ([string]$script:WorkflowAiConversationHistory).Length
        $openFormCount = @([Windows.Forms.Application]::OpenForms).Count
        $controlCount=Get-WorkflowControlCount $script:MainForm
        $fileTreeRequestCount=if($null-eq$script:CodexConversationFileTreeRequestIds){0}else{[int]$script:CodexConversationFileTreeRequestIds.Count}
        $fileTreeContextCount=if($null-eq$script:CodexConversationFileTreeRequestContexts){0}else{[int]$script:CodexConversationFileTreeRequestContexts.Count}
        $codexSessionCacheCount=if($null-eq$script:CodexSessionCache){0}else{[int]@($script:CodexSessionCache).Count}
        $managedMemory=[GC]::GetTotalMemory($false)
        $clr = Get-WorkflowClrMemorySnapshot
        $builder = New-Object Text.StringBuilder
        [void]$builder.AppendLine('使驾轻量内存诊断（一次性快照）')
        [void]$builder.AppendLine(('采集时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('【进程】')
        [void]$builder.AppendLine(('PID：{0}    启动时间：{1}' -f $process.Id, $process.StartTime.ToString('yyyy-MM-dd HH:mm:ss')))
        [void]$builder.AppendLine(('工作集：{0}    私有内存：{1}    虚拟内存：{2}' -f (Format-WorkflowMemorySize $process.WorkingSet64), (Format-WorkflowMemorySize $process.PrivateMemorySize64), (Format-WorkflowMemorySize $process.VirtualMemorySize64)))
        [void]$builder.AppendLine(('句柄：{0}    线程：{1}    打开窗口：{2}' -f $process.HandleCount, $process.Threads.Count, $openFormCount))
        [void]$builder.AppendLine(('GC.GetTotalMemory：{0}    主窗口控件：{1}' -f (Format-WorkflowMemorySize $managedMemory),$controlCount))
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('【CLR 托管堆】')
        if ([string]::IsNullOrWhiteSpace([string]$clr.Instance)) {
            [void]$builder.AppendLine('性能计数器不可用，无法读取 Gen 2 / LOH 细分。')
        } else {
            [void]$builder.AppendLine(('实例：{0}' -f $clr.Instance))
            [void]$builder.AppendLine(('总堆：{0}    Gen 0：{1}    Gen 1：{2}' -f (Format-WorkflowMemorySize ([double]$clr.Heap)), (Format-WorkflowMemorySize ([double]$clr.Gen0)), (Format-WorkflowMemorySize ([double]$clr.Gen1))))
            [void]$builder.AppendLine(('Gen 2：{0}    LOH：{1}    CLR 已提交：{2}' -f (Format-WorkflowMemorySize ([double]$clr.Gen2)), (Format-WorkflowMemorySize ([double]$clr.Loh)), (Format-WorkflowMemorySize ([double]$clr.Committed))))
            [void]$builder.AppendLine(('% GC：{0}' -f $(if ($null -eq $clr.GcPercent) { '不可用' } else { '{0:N2}%' -f ([double]$clr.GcPercent) })))
        }
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('【会话与界面缓存】')
        [void]$builder.AppendLine(('会话快照：{0} 个，{1}' -f $snapshotCount, (Format-WorkflowMemorySize ($snapshotCharacters * 2))))
        [void]$builder.AppendLine(('历史缓存：{0} 个，{1}' -f $historyCount, (Format-WorkflowMemorySize ($historyCharacters * 2))))
        [void]$builder.AppendLine(('使驾 AI 历史：{0}，气泡控件：{1}，转录片段：{2}' -f (Format-WorkflowMemorySize ($workflowAiHistoryCharacters * 2)), $bubbleCount, $transcriptPartCount))
        [void]$builder.AppendLine(('待发送图片：{0}，会话进程记录：{1}' -f $pendingImageCount, $conversationProcessCount))
        [void]$builder.AppendLine(('Codex 会话摘要缓存：{0}，文件树请求：{1}，请求上下文：{2}' -f $codexSessionCacheCount,$fileTreeRequestCount,$fileTreeContextCount))
        [void]$builder.AppendLine(('自动会话刷新：{0} 次，无变化快速命中：{1} 次，快照重建：{2} 次' -f $script:CodexConversationAutomaticRefreshes,$script:CodexConversationSnapshotNoChangeHits,$script:CodexConversationSnapshotRebuilds))
        [void]$builder.AppendLine(('会话管理状态复用：{0} 次，新建：{1} 次' -f $script:SessionManagerStateReuseHits,$script:SessionManagerStateBuilds))
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('【运行中任务日志】')
        [void]$builder.AppendLine(('运行中任务：{0} 个，日志：{1} 行，文本约：{2}' -f $runningTaskCount, $runningLogCount, (Format-WorkflowMemorySize ($runningLogCharacters * 2))))
        if ($runningItems.Count -gt 0) {
            [void]$builder.AppendLine('日志占用较大的任务：')
            foreach ($item in @($runningItems | Sort-Object Characters -Descending | Select-Object -First 8)) {
                [void]$builder.AppendLine(('  - {0}：{1} 行，约 {2}' -f $item.Key, $item.Count, (Format-WorkflowMemorySize ($item.Characters * 2))))
            }
        }
        if ($snapshotItems.Count -gt 0) {
            [void]$builder.AppendLine('')
            [void]$builder.AppendLine('【会话快照占用较大的项目】')
            foreach ($item in @($snapshotItems | Sort-Object Characters -Descending | Select-Object -First 8)) {
                [void]$builder.AppendLine(('  - {0}：约 {1}' -f $item.Key, (Format-WorkflowMemorySize ($item.Characters * 2))))
            }
        }
        if ($historyItems.Count -gt 0) {
            [void]$builder.AppendLine('')
            [void]$builder.AppendLine('【历史缓存占用较大的项目】')
            foreach ($item in @($historyItems | Sort-Object Characters -Descending | Select-Object -First 8)) {
                [void]$builder.AppendLine(('  - {0}：约 {1}' -f $item.Key, (Format-WorkflowMemorySize ($item.Characters * 2))))
            }
        }
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('说明：文本大小按 UTF-16 粗略估算，未计入控件内部缓存、对象引用和原生内存；该窗口只读取摘要，不会主动清理数据。')
        return $builder.ToString()
    } catch {
        return ('内存诊断采集失败：' + $_.Exception.Message)
    } finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
    }
}

function Show-WorkflowMemoryDiagnostics {
    $form = New-Object Windows.Forms.Form
    Set-WorkflowFormScaling $form
    $form.Text = '内存诊断 - 使驾'
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'Sizable'
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(760, 620)
    $form.MinimumSize = New-Object Drawing.Size(620, 420)
    $form.Font = New-UiFont 9
    Set-WorkflowWindowIcon $form

    $output = New-Object Windows.Forms.TextBox
    $output.Location = New-Object Drawing.Point(18, 18)
    $output.Size = New-Object Drawing.Size(724, 520)
    $output.Anchor = 'Top,Bottom,Left,Right'
    $output.Multiline = $true
    $output.ReadOnly = $true
    $output.ScrollBars = 'Both'
    $output.WordWrap = $false
    $output.Font = New-Object Drawing.Font('Consolas', 9)
    $output.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)
    $output.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $form.Controls.Add($output)

    $refresh = Add-UiButton $form '重新采集' 18 552 110 34 'Primary'
    $copy = Add-UiButton $form '复制报告' 138 552 110 34
    $close = Add-UiButton $form '关闭' 632 552 110 34
    $refresh.Anchor = 'Bottom,Left'
    $copy.Anchor = 'Bottom,Left'
    $close.Anchor = 'Bottom,Right'
    $refresh.Add_Click({ $output.Text = Get-WorkflowMemoryDiagnosticsText; $output.SelectionStart = 0; $output.SelectionLength = 0 })
    $copy.Add_Click({ try { [Windows.Forms.Clipboard]::SetText($output.Text) } catch { Show-Message ('复制诊断报告失败：' + $_.Exception.Message) '内存诊断' ([Windows.Forms.MessageBoxIcon]::Warning) } })
    $close.Add_Click({ $form.Close() })
    $form.Add_Shown({ $output.Text = Get-WorkflowMemoryDiagnosticsText; $output.SelectionStart = 0; $output.SelectionLength = 0 })
    Apply-UiTheme $form
    try{[void]$form.ShowDialog($script:MainForm)}finally{if($null-ne$form-and-not$form.IsDisposed){$form.Dispose()}}
}

function Show-WorkflowWorkspace {
    if ($null -ne $script:CodexConversationOutput) {
        if($script:CodexConversationMode -eq 'WorkflowAi'){$script:WorkflowAiConversationHistory=$script:CodexConversationOutput.Text}
        elseif(-not [string]::IsNullOrWhiteSpace($script:CodexConversationProjectId)){Set-CodexConversationHistoryCache (Get-CodexConversationHistoryKey 'Project' $script:CodexConversationProjectId $script:CodexConversationSessionId) $script:CodexConversationOutput.Text}
    }
    if($null -ne $script:CodexConversationPanel){$script:CodexConversationPanel.Visible=$false}
    if($null -ne $script:RunningTasksPanel){$script:RunningTasksPanel.Visible=$false}
    Hide-EmbeddedCommonPromptsPanel
    if($null -ne $script:SessionManagerPanel){$script:SessionManagerPanel.Visible=$false}
    if($null -ne $script:WorkflowSettingsPanel){$script:WorkflowSettingsPanel.Visible=$true}
    if($null -ne $script:WorkflowLogPanel){$script:WorkflowLogPanel.Visible=$true}
    if($null -ne $script:Canvas){$script:Canvas.Visible=$true; $script:Canvas.BringToFront()}
}

function Get-SelectedRunningTaskId {
    if($null-eq$script:RunningTasksGrid-or$script:RunningTasksGrid.SelectedRows.Count-eq0){return ''}
    $row=Get-UiSelectedItemSafe $script:RunningTasksGrid.SelectedRows
    if($null-eq$row){return ''}
    return [string]$row.Tag
}

function Format-RunningTaskDuration {
    param([datetime]$StartedAt)
    $duration=(Get-Date)-$StartedAt
    if($duration.TotalHours-ge1){return('{0:00}:{1:00}:{2:00}'-f([int]$duration.TotalHours),$duration.Minutes,$duration.Seconds)}
    return('{0:00}:{1:00}'-f([int]$duration.TotalMinutes),$duration.Seconds)
}

function Format-RunningTaskLogLine {
    param($Log)
    $time=''
    try{$time=([datetime]$Log.At).ToLocalTime().ToString('HH:mm:ss.fff')}catch{$time=(Get-Date).ToString('HH:mm:ss.fff')}
    return('{0} [{1}] {2}'-f$time,([string]$Log.Level),([string]$Log.Message))
}

function Refresh-RunningTaskDetails {
    if($null-eq$script:RunningTaskLogBox-or$script:RunningTaskLogBox.IsDisposed){return}
    $workflowId=Get-SelectedRunningTaskId
    if([string]::IsNullOrWhiteSpace($workflowId)-or-not$script:RunningJobs.ContainsKey($workflowId)){
        $displayChanged=-not[string]::IsNullOrWhiteSpace($script:RunningTaskDisplayedId)
        $script:RunningTaskDisplayedId='';$script:RunningTaskDisplayedLogCount=0;$script:RunningTaskLogNeedsReset=$false
        if($script:RunningTaskTitle.Text-ne'请选择一个运行中的任务'){$script:RunningTaskTitle.Text='请选择一个运行中的任务'}
        if($script:RunningTaskMeta.Text-ne'任务结束后会从本页移除，完整日志仍保存在执行日志中。'){$script:RunningTaskMeta.Text='任务结束后会从本页移除，完整日志仍保存在执行日志中。'}
        if($displayChanged-and$script:RunningTaskLogBox.TextLength-gt0){$script:RunningTaskLogBox.Clear()}
        if($script:RunningTaskStopButton.Enabled){$script:RunningTaskStopButton.Enabled=$false}
        return
    }
    $record=$script:RunningJobs[$workflowId]
    $title=[string]$record.WorkflowName
    if($script:RunningTaskTitle.Text-ne$title){$script:RunningTaskTitle.Text=$title}
    $activePid=if([int]$record.ActiveProcessId-gt0){[string]$record.ActiveProcessId}else{'-'}
    $meta=('状态：{0}    当前节点：{1} [{2}]    已运行：{3}    Worker PID：{4}    当前进程：{5}'-f[string]$record.Status,[string]$record.CurrentNodeName,[string]$record.CurrentNodeType,(Format-RunningTaskDuration $record.StartedAt),[string]$record.Worker.Process.Id,$activePid)
    if($script:RunningTaskMeta.Text-ne$meta){$script:RunningTaskMeta.Text=$meta}
    $stopEnabled=-not$record.StopRequested-and-not$record.Worker.Process.HasExited
    if($script:RunningTaskStopButton.Enabled-ne$stopEnabled){$script:RunningTaskStopButton.Enabled=$stopEnabled}
    $resetLogView=$false
    if($script:RunningTaskDisplayedId-ne$workflowId-or$script:RunningTaskDisplayedLogCount-gt$record.Logs.Count-or$script:RunningTaskLogNeedsReset){
        if($script:RunningTaskLogBox.TextLength-gt0){$script:RunningTaskLogBox.Clear()}
        $script:RunningTaskDisplayedId=$workflowId;$script:RunningTaskDisplayedLogCount=[Math]::Max(0,$record.Logs.Count-1200);$script:RunningTaskLogNeedsReset=$false;$resetLogView=$true
    }
    $appended=$false
    if($script:RunningTaskDisplayedLogCount-lt$record.Logs.Count){
        $builder=New-Object Text.StringBuilder
        while($script:RunningTaskDisplayedLogCount-lt$record.Logs.Count){
            $log=$record.Logs[$script:RunningTaskDisplayedLogCount]
            [void]$builder.AppendLine((Format-RunningTaskLogLine $log))
            $script:RunningTaskDisplayedLogCount++;$appended=$true
        }
        if($appended){$script:RunningTaskLogBox.AppendText($builder.ToString())}
    }
    if($appended-or$resetLogView){
        $script:RunningTaskLogBox.SelectionStart=$script:RunningTaskLogBox.TextLength
        $script:RunningTaskLogBox.SelectionLength=0
        $script:RunningTaskLogBox.ScrollToCaret()
    }
}

function Refresh-RunningTasksView {
    if($null-eq$script:RunningTasksGrid-or$script:RunningTasksGrid.IsDisposed){return}
    $selectedId=Get-SelectedRunningTaskId
    if($null-ne$script:RunningTasksButton){$buttonText=if($script:RunningJobs.Count-gt0){'运行中任务 ('+$script:RunningJobs.Count+')'}else{'运行中任务'};if($script:RunningTasksButton.Text-ne$buttonText){$script:RunningTasksButton.Text=$buttonText}}
    if($null-eq$script:RunningTasksPanel-or-not$script:RunningTasksPanel.Visible){return}
    $rowsById=@{}
    foreach($row in @($script:RunningTasksGrid.Rows)){if($null-ne$row.Tag){$rowsById[[string]$row.Tag]=$row}}
    for($index=$script:RunningTasksGrid.Rows.Count-1;$index-ge0;$index--){$row=Get-UiIndexedItemSafe $script:RunningTasksGrid.Rows $index;if($null-ne$row-and($null-eq$row.Tag-or-not$script:RunningJobs.ContainsKey([string]$row.Tag))){$script:RunningTasksGrid.Rows.RemoveAt($index)}}
    foreach($workflowId in @($script:RunningJobs.Keys|Sort-Object)){
        $record=$script:RunningJobs[$workflowId]
        if($rowsById.ContainsKey($workflowId)){$row=$rowsById[$workflowId]}
        else{$rowIndex=$script:RunningTasksGrid.Rows.Add();$row=Get-UiIndexedItemSafe $script:RunningTasksGrid.Rows $rowIndex;if($null-ne$row){$row.Tag=$workflowId}}
        if($null-eq$row){continue}
        $values=@([string]$record.WorkflowName,[string]$record.Status,[string]$record.CurrentNodeName,(Format-RunningTaskDuration $record.StartedAt),[string]$record.Worker.Process.Id)
        for($cellIndex=0;$cellIndex-lt$values.Count;$cellIndex++){$cell=Get-UiIndexedItemSafe $row.Cells $cellIndex;if($null-ne$cell-and[string]$cell.Value-ne[string]$values[$cellIndex]){$cell.Value=$values[$cellIndex]}}
    }
    $selectedGridRow=$null
    if(-not[string]::IsNullOrWhiteSpace($selectedId)){foreach($candidateRow in @($script:RunningTasksGrid.Rows)){if([string]$candidateRow.Tag-eq$selectedId){$selectedGridRow=$candidateRow;break}}}
    if($null-ne$selectedGridRow){
        $selectedCurrentRow=Get-UiSelectedItemSafe $script:RunningTasksGrid.SelectedRows
        if($null-eq$selectedCurrentRow-or[string]$selectedCurrentRow.Tag-ne$selectedId){$selectedGridRow.Selected=$true;$firstCell=Get-UiIndexedItemSafe $selectedGridRow.Cells 0;if($null-ne$firstCell){$script:RunningTasksGrid.CurrentCell=$firstCell}}
    }elseif($script:RunningTasksGrid.SelectedRows.Count-eq0-and$script:RunningTasksGrid.Rows.Count-gt0){$firstRow=Get-UiIndexedItemSafe $script:RunningTasksGrid.Rows 0;if($null-ne$firstRow){$firstRow.Selected=$true;$firstCell=Get-UiIndexedItemSafe $firstRow.Cells 0;if($null-ne$firstCell){$script:RunningTasksGrid.CurrentCell=$firstCell}}}
    Refresh-RunningTaskDetails
}

function Show-RunningTasksPage {
    if($null-ne$script:CodexConversationPanel){$script:CodexConversationPanel.Visible=$false}
    Hide-EmbeddedCommonPromptsPanel
    if($null-ne$script:SessionManagerPanel){$script:SessionManagerPanel.Visible=$false}
    if($null-ne$script:WorkflowSettingsPanel){$script:WorkflowSettingsPanel.Visible=$false}
    if($null-ne$script:WorkflowLogPanel){$script:WorkflowLogPanel.Visible=$false}
    if($null-ne$script:Canvas){$script:Canvas.Visible=$false}
    if($null-ne$script:RunningTasksPanel){$script:RunningTasksPanel.Visible=$true;$script:RunningTasksPanel.BringToFront()}
    Refresh-RunningTasksView
}

function Hide-EmbeddedCommonPromptsPanel {
    if($null-ne$script:CommonPromptsForm-and-not$script:CommonPromptsForm.IsDisposed-and$script:CommonPromptsPanel.Parent-eq$script:CommonPromptsForm){return}
    if($null-ne$script:CommonPromptsPanel){$script:CommonPromptsPanel.Visible=$false}
}

function Restore-CommonPromptsPanelToMain {
    if($null-eq$script:CommonPromptsPanel-or$script:CommonPromptsPanel.IsDisposed){return}
    if($null-ne$script:CommonPromptsPanel.Parent){$script:CommonPromptsPanel.Parent.Controls.Remove($script:CommonPromptsPanel)}
    if($null-ne$script:CommonPromptsHost-and-not$script:CommonPromptsHost.IsDisposed){$script:CommonPromptsHost.Controls.Add($script:CommonPromptsPanel);$script:CommonPromptsPanel.Dock='Fill';$script:CommonPromptsPanel.Visible=$false}
}

function Close-CommonPromptsWindow {
    if($null-eq$script:CommonPromptsForm-or$script:CommonPromptsForm.IsDisposed){Restore-CommonPromptsPanelToMain;return}
    Restore-CommonPromptsPanelToMain
    $form=$script:CommonPromptsForm;$script:CommonPromptsForm=$null
    try{$form.Close()}catch{}
}

function Show-CommonPromptsPage {
    if($null-ne$script:CommonPromptsForm-and-not$script:CommonPromptsForm.IsDisposed){$script:CommonPromptsForm.Show();$script:CommonPromptsForm.BringToFront();$script:CommonPromptsForm.Activate();Refresh-CommonPromptList;return}
    if($null-eq$script:CommonPromptsPanel-or$script:CommonPromptsPanel.IsDisposed){return}
    $form=New-Object Windows.Forms.Form;Set-WorkflowFormScaling $form;$form.Text='常用提示词';$form.StartPosition='Manual';$form.FormBorderStyle='SizableToolWindow';$form.MinimizeBox=$false;$form.MaximizeBox=$true;$form.ShowInTaskbar=$false;$form.MinimumSize=New-Object Drawing.Size(620,420);$form.ClientSize=New-Object Drawing.Size(780,560);$form.Font=New-UiFont 9;Set-WorkflowWindowIcon $form
    if($null-ne$script:CommonPromptsPanel.Parent){$script:CommonPromptsPanel.Parent.Controls.Remove($script:CommonPromptsPanel)}
    $script:CommonPromptsPanel.Dock='Fill';$script:CommonPromptsPanel.Visible=$true;$form.Controls.Add($script:CommonPromptsPanel)
    $script:CommonPromptsForm=$form
    $form.PerformLayout()
    if($null-ne$script:MainForm-and-not$script:MainForm.IsDisposed-and$script:MainForm.IsHandleCreated){
        try{
            $ownerBounds=$script:MainForm.Bounds
            $workingArea=[Windows.Forms.Screen]::FromControl($script:MainForm).WorkingArea
            $x=$ownerBounds.Left+[int][Math]::Round(($ownerBounds.Width-$form.Width)/2.0)
            $y=$ownerBounds.Top+[int][Math]::Round([Math]::Max(40,$ownerBounds.Height*0.24))
            $x=[Math]::Max($workingArea.Left,[Math]::Min($x,$workingArea.Right-$form.Width))
            $y=[Math]::Max($workingArea.Top,[Math]::Min($y,$workingArea.Bottom-$form.Height))
            $form.Location=New-Object Drawing.Point($x,$y)
        }catch{}
    }
    $form.Add_FormClosing({Restore-CommonPromptsPanelToMain})
    $form.Add_FormClosed({$script:CommonPromptsForm=$null})
    $form.Show($script:MainForm);$form.BringToFront();$form.Activate();Refresh-CommonPromptList
}

function Refresh-CommonPromptList {
    if($null-eq$script:CommonPromptList-or$script:CommonPromptList.IsDisposed){return}
    $selectedText=if($script:CommonPromptList.SelectedIndex-ge0){[string]$script:CommonPromptList.SelectedItem}else{''}
    $script:CommonPromptList.BeginUpdate()
    try{
        $script:CommonPromptList.Items.Clear()
        foreach($prompt in @($script:GlobalSettings.CommonPrompts)){if(-not[string]::IsNullOrWhiteSpace([string]$prompt)){[void]$script:CommonPromptList.Items.Add([string]$prompt)}}
    }finally{$script:CommonPromptList.EndUpdate()}
    if(-not[string]::IsNullOrWhiteSpace($selectedText)){$selectedIndex=$script:CommonPromptList.Items.IndexOf($selectedText);if($selectedIndex-ge0){$script:CommonPromptList.SelectedIndex=$selectedIndex}}
    if($script:CommonPromptList.SelectedIndex-lt0-and$script:CommonPromptList.Items.Count-gt0){$script:CommonPromptList.SelectedIndex=0}
    Update-CommonPromptActionState
}

function Update-CommonPromptActionState {
    if($null-eq$script:CommonPromptList-or$script:CommonPromptList.IsDisposed){return}
    $hasSelection=$script:CommonPromptList.SelectedIndex-ge0
    if($null-ne$script:CommonPromptEditButton){$script:CommonPromptEditButton.Enabled=$hasSelection}
    if($null-ne$script:CommonPromptDeleteButton){$script:CommonPromptDeleteButton.Enabled=$hasSelection}
    if($null-ne$script:CommonPromptCopyButton){$script:CommonPromptCopyButton.Enabled=$hasSelection}
}

function Show-CommonPromptEditor {
    param([string]$InitialText='',[string]$Title='新增常用提示词')
    $form=New-Object Windows.Forms.Form;Set-WorkflowFormScaling $form;$form.Text=$Title;$form.StartPosition='CenterParent';$form.FormBorderStyle='Sizable';$form.MaximizeBox=$false;$form.MinimizeBox=$false;$form.MinimumSize=New-Object Drawing.Size(620,360);$form.ClientSize=New-Object Drawing.Size(760,460);$form.Font=New-UiFont 9;Set-WorkflowWindowIcon $form
    $titleLabel=Add-UiLabel $form '提示词内容' 20 18 140 26;$titleLabel.Font=New-UiFont 10 ([Drawing.FontStyle]::Bold)
    $textBox=New-Object Windows.Forms.TextBox;$textBox.Location=New-Object Drawing.Point(20,52);$textBox.Size=New-Object Drawing.Size(720,318);$textBox.Anchor='Top,Bottom,Left,Right';$textBox.Multiline=$true;$textBox.AcceptsReturn=$true;$textBox.ScrollBars='Vertical';$textBox.WordWrap=$true;$textBox.Text=$InitialText;$textBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',10.5);$textBox.Tag='CommonPromptEditorInput';$form.Controls.Add($textBox)
    $hint=Add-UiLabel $form '支持多行编辑；保存后会保留换行，可直接复制到 Codex 或工作任务中使用。' 20 382 560 24 -Muted;$hint.Anchor='Bottom,Left'
    $save=Add-UiButton $form '保存' 638 410 102 34 'Primary';$save.Anchor='Bottom,Right';$cancel=Add-UiButton $form '取消' 530 410 96 34;$cancel.Anchor='Bottom,Right';$cancel.DialogResult='Cancel';$form.CancelButton=$cancel;$form.AcceptButton=$save
    $save.Add_Click({$lineFeed=[string][char]10;$value=[regex]::Replace($textBox.Text,'\r\n?',$lineFeed).Trim();if([string]::IsNullOrWhiteSpace($value)){Show-Message '提示词不能为空。' $Title ([Windows.Forms.MessageBoxIcon]::Warning);return};$script:CommonPromptEditorResult=$value;$form.DialogResult='OK';$form.Close()})
    $textBox.Add_KeyDown({param($sender,$e);if($e.Control-and$e.KeyCode-eq[Windows.Forms.Keys]::Enter){$save.PerformClick();$e.SuppressKeyPress=$true;$e.Handled=$true}})
    Apply-UiTheme $form;$script:CommonPromptEditorResult='';$textBox.SelectAll();[void]$textBox.Focus();$result=''
    try{if($form.ShowDialog($script:MainForm)-eq[Windows.Forms.DialogResult]::OK){$result=[string]$script:CommonPromptEditorResult}}
    finally{if($null-ne$form-and-not$form.IsDisposed){$form.Dispose()}}
    $script:CommonPromptEditorResult='';return $result
}

function ConvertTo-CommonPromptValue {
    param($Value)
    $values=@(
        @($Value) |
        Where-Object { $_ -isnot [bool] } |
        ForEach-Object { $lineFeed=[string][char]10;$normalized=[regex]::Replace([string]$_,'\r\n?',$lineFeed);$normalized.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'False' }
    )
    if($values.Count-eq0){return ''}
    return [string]$values[$values.Count-1]
}

function Add-CommonPrompt {
    $value=ConvertTo-CommonPromptValue @(Show-CommonPromptEditor);if([string]::IsNullOrWhiteSpace($value)){return}
    $script:GlobalSettings.CommonPrompts=@($script:GlobalSettings.CommonPrompts)+$value;Save-GlobalSettings;Refresh-CommonPromptList;$script:CommonPromptList.SelectedIndex=$script:CommonPromptList.Items.Count-1
}

function Edit-SelectedCommonPrompt {
    if($null-eq$script:CommonPromptList-or$script:CommonPromptList.SelectedIndex-lt0){return}
    $index=$script:CommonPromptList.SelectedIndex;$value=ConvertTo-CommonPromptValue @(Show-CommonPromptEditor ([string]$script:CommonPromptList.SelectedItem) '编辑常用提示词');if([string]::IsNullOrWhiteSpace($value)){return}
    $prompts=@($script:GlobalSettings.CommonPrompts);$prompts[$index]=$value;$script:GlobalSettings.CommonPrompts=$prompts;Save-GlobalSettings;Refresh-CommonPromptList;$script:CommonPromptList.SelectedIndex=$index
}

function Remove-SelectedCommonPrompt {
    if($null-eq$script:CommonPromptList-or$script:CommonPromptList.SelectedIndex-lt0){return}
    $index=$script:CommonPromptList.SelectedIndex;$value=[string]$script:CommonPromptList.SelectedItem
    $answer=[Windows.Forms.MessageBox]::Show(('删除常用提示词“'+$value+'”？'),'删除提示词',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning);if($answer-ne[Windows.Forms.DialogResult]::Yes){return}
    $prompts=New-Object System.Collections.Generic.List[string];foreach($prompt in @($script:GlobalSettings.CommonPrompts)){$prompts.Add([string]$prompt)};$prompts.RemoveAt($index);$script:GlobalSettings.CommonPrompts=$prompts.ToArray();Save-GlobalSettings;Refresh-CommonPromptList
}

function Copy-SelectedCommonPrompt {
    if($null-eq$script:CommonPromptList-or$script:CommonPromptList.SelectedIndex-lt0){return $false}
    try{[Windows.Forms.Clipboard]::SetText([string]$script:CommonPromptList.SelectedItem);if($null-ne$script:StatusLabel){$script:StatusLabel.Text='常用提示词已复制'};return $true}catch{Write-WorkflowLog ('复制常用提示词失败：'+$_.Exception.Message) 'ERROR';return $false}
}

function Set-CodexConversationStatus {
    param([string]$Text, [string]$Tone = 'Ready')
    if ($null -eq $script:CodexConversationStatus) { return }
    $script:CodexConversationStatus.Text = $Text
    $script:CodexConversationStatus.ForeColor = switch ($Tone) {
        'Busy' { [Drawing.Color]::FromArgb(180, 83, 9) }
        'Error' { [Drawing.Color]::FromArgb(185, 28, 28) }
        default { [Drawing.Color]::FromArgb(21, 128, 61) }
    }
}

function Get-CodexConversationProcessKey {
    param([string]$Mode = 'Project', [string]$ProjectId = '', [string]$SessionId = '', [int]$SessionIndex = -1)
    if ($Mode -eq 'WorkflowAi') { return 'WorkflowAi' }
    $sessionKey=if([string]::IsNullOrWhiteSpace($SessionId)){if($SessionIndex -ge 0){'_new-'+[string]$SessionIndex}else{'_new'}}else{$SessionId}
    return 'Project:' + $ProjectId + ':' + $sessionKey
}

function Test-CodexConversationOutputReady {
    param($Record)
    if ($null -eq $Record) { return $false }
    $outputPath = [string](Get-UiConfigValue $Record 'OutputPath' '')
    if ([string]::IsNullOrWhiteSpace($outputPath)) { return $false }
    try {
        if (-not [IO.File]::Exists($outputPath)) { return $false }
        $file = New-Object IO.FileInfo($outputPath)
        if ($file.Length -le 0) { return $false }
        $startedAtValue = Get-UiConfigValue $Record 'StartedAt' $null
        if ($null -ne $startedAtValue) {
            try {
                if ($file.LastWriteTimeUtc -lt ([datetime]$startedAtValue).ToUniversalTime()) { return $false }
            } catch { }
        }
        return $true
    } catch {
        return $false
    }
}

function Test-CodexConversationProcessRunning {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key) -or -not $script:CodexConversationProcesses.ContainsKey($Key)) { return $false }
    $record = $script:CodexConversationProcesses[$Key]
    if ($null -eq $record -or (Test-CodexConversationOutputReady $record)) { return $false }
    try { return -not $record.Process.HasExited } catch { return $false }
}

function Test-CodexConversationProcessBusy {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key) -or -not $script:CodexConversationProcesses.ContainsKey($Key)) { return $false }
    $record = $script:CodexConversationProcesses[$Key]
    if ($null -eq $record) { return $false }
    return [string](Get-UiConfigValue $record 'FinalizeState' 'Running') -ne 'Finalized'
}

function Set-CodexConversationRecordValue {
    param($Record, [string]$Name, $Value)
    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Name)) { return }
    $property = $Record.PSObject.Properties[$Name]
    if ($null -eq $property) { $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $property.Value = $Value }
}

function Get-CodexConversationOutputTaskState {
    param($Task, [string]$StreamName, [switch]$Force)
    if ($null -eq $Task) { return [pscustomobject]@{ Completed=$true; Text=''; Error=''; TimedOut=$false } }
    try {
        if ($Task -is [WorkflowProcessStreamCapture]) {
            $capture = $Task
            $captureCompleted = [bool]$capture.IsCompleted
            if (-not $captureCompleted -and -not $Force) {
                return [pscustomobject]@{ Completed=$false; Text=''; Error=''; TimedOut=$false }
            }
            $captureText = ''
            try { $captureText = [string]$capture.GetText() } catch { $captureText = '' }
            $captureError = [string](Get-UiConfigValue $capture 'Error' '')
            if (-not $captureCompleted -and $Force) {
                $timeoutError = $StreamName + ' 输出排空超时'
                if (-not [string]::IsNullOrWhiteSpace($captureError)) { $timeoutError += '：' + $captureError }
                return [pscustomobject]@{ Completed=$true; Text=$captureText; Error=$timeoutError; TimedOut=$true }
            }
            return [pscustomobject]@{ Completed=$true; Text=$captureText; Error=$captureError; TimedOut=$false }
        }
        if (-not [bool]$Task.IsCompleted) {
            if ($Force) { return [pscustomobject]@{ Completed=$true; Text=''; Error=($StreamName + ' 输出排空超时'); TimedOut=$true } }
            return [pscustomobject]@{ Completed=$false; Text=''; Error=''; TimedOut=$false }
        }
        if ([bool]$Task.IsCanceled) { return [pscustomobject]@{ Completed=$true; Text=''; Error=($StreamName + ' 输出读取已取消'); TimedOut=$false } }
        if ([bool]$Task.IsFaulted) {
            $message = if ($null -ne $Task.Exception) { [string]$Task.Exception.GetBaseException().Message } else { '未知错误' }
            return [pscustomobject]@{ Completed=$true; Text=''; Error=($StreamName + ' 输出读取失败：' + $message); TimedOut=$false }
        }
        return [pscustomobject]@{ Completed=$true; Text=[string]$Task.Result; Error=''; TimedOut=$false }
    } catch {
        return [pscustomobject]@{ Completed=$true; Text=''; Error=($StreamName + ' 输出读取失败：' + $_.Exception.Message); TimedOut=$false }
    }
}

function Dispose-CodexConversationOutputCapture {
    param($Record)
    if ($null -eq $Record) { return }
    foreach ($stream in @(
        (Get-UiConfigValue $Record 'StdOut' $null),
        (Get-UiConfigValue $Record 'StdErr' $null)
    )) {
        if ($stream -is [WorkflowProcessStreamCapture]) {
            try { $stream.Dispose() } catch { }
        }
    }
}

function Get-ProjectCodexSessionBusyRecord {
    param($Project,[string]$SessionId='')
    if ($null -eq $Project) { return $null }
    $session=Get-ProjectCodexSession $Project $SessionId
    $sessionId=if($null-ne$session){[string]$session.SessionId}else{''}
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return $null }
    foreach ($record in @($script:RunningJobs.Values)) {
        if ([string](Get-UiConfigValue $record 'ActiveCodexSessionId' '') -eq $sessionId) { return $record }
    }
    return $null
}

function Get-ProjectSessionManagerState {
    param($Project,$Session=$null,[int]$SessionIndex=-1,[hashtable]$ExistingStatesById=$null)
    if ($null -eq $Project) { return $null }
    $projectId = [string]$Project.Id
    if($null-eq$Session){$Session=Get-ProjectPrimaryCodexSession $Project}
    $sessionId=if($null-ne$Session){[string]$Session.SessionId}else{''}
    $conversationKey = Get-CodexConversationProcessKey 'Project' $projectId $sessionId $SessionIndex
    $conversationRunning = Test-CodexConversationProcessRunning $conversationKey
    $conversationBusy = Test-CodexConversationProcessBusy $conversationKey
    $busyWorkflow = Get-ProjectCodexSessionBusyRecord $Project $sessionId
    $status = if ($conversationRunning) { '对话进行中' } elseif ($conversationBusy) { '回复同步中' } elseif ($null -ne $busyWorkflow) { '工作流调用中' } elseif ([string]::IsNullOrWhiteSpace($sessionId)) { '未创建' } else { '已完成' }
    $updatedAt = [string](Get-UiConfigValue $Project 'UpdatedAt' '')
    $historySessionRecord = if ([string]::IsNullOrWhiteSpace($sessionId)) { $null } else { Get-CodexSessionRecord $sessionId }
    if ($null -ne $historySessionRecord -and -not [string]::IsNullOrWhiteSpace([string]$historySessionRecord.last_write_time)) { $updatedAt = [string]$historySessionRecord.last_write_time }
    $sortTime = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($updatedAt)) { try { $sortTime = ([datetime]$updatedAt).ToUniversalTime() } catch { } }
    $description=if($null-ne$Session){[string]$Session.Description}else{'无描述'}
    if([string]::IsNullOrWhiteSpace($description)){$description='无描述'}
    $rowKey=if([string]::IsNullOrWhiteSpace($sessionId)){$projectId+'|_new|'+[string]$SessionIndex+'|'+$description}else{$projectId+'|'+$sessionId}
    $model=if($null-ne$Session){[string]$Session.CodexModel}else{''}
    $workingDirectory=[string](Get-UiConfigValue $Project 'DefaultWorkingDirectory' '')
    $busyWorkflowName=if($null-ne$busyWorkflow){[string]$busyWorkflow.WorkflowName}else{''}
    $signature=@($projectId,[string]$Project.Name,$status,$description,$sessionId,$model,$workingDirectory,$updatedAt,[string]$sortTime.Ticks,$busyWorkflowName)-join[char]31
    if($null-ne$ExistingStatesById-and$ExistingStatesById.ContainsKey($rowKey)){
        $existingState=$ExistingStatesById[$rowKey]
        if($null-ne$existingState-and[string](Get-UiConfigValue $existingState 'Signature' '')-eq$signature){$script:SessionManagerStateReuseHits++;return $existingState}
    }
    $script:SessionManagerStateBuilds++
    return [pscustomobject]@{
        RowKey=$rowKey; ProjectId=$projectId; ProjectName=[string]$Project.Name; Status=$status; Description=$description; SessionId=$sessionId
        Model=$model; WorkingDirectory=$workingDirectory; UpdatedAt=$updatedAt; SortTime=$sortTime; BusyWorkflowName=$busyWorkflowName; Signature=$signature
    }
}

function Get-SelectedSessionManagerState {
    if($null-eq$script:SessionManagerGrid-or$script:SessionManagerGrid.SelectedRows.Count-eq0){return $null}
    $selectedRow=Get-UiSelectedItemSafe $script:SessionManagerGrid.SelectedRows
    if($null-eq$selectedRow){return $null}
    return $selectedRow.Tag
}

function Get-SelectedSessionManagerProjectId {
    $state=Get-SelectedSessionManagerState;if($null-eq$state){return ''}
    return [string](Get-UiConfigValue $state 'ProjectId' '')
}

function Get-SelectedSessionManagerSessionId {
    $state=Get-SelectedSessionManagerState;if($null-eq$state){return ''}
    return [string](Get-UiConfigValue $state 'SessionId' '')
}

function Refresh-SessionManagerView {
    param([switch]$Force)
    if($null-eq$script:SessionManagerGrid-or$script:SessionManagerGrid.IsDisposed-or$script:SessionManagerRefreshActive){return}
    if(-not$Force-and((Get-Date)-$script:SessionManagerLastRefreshAt).TotalMilliseconds-lt750){return}
    $script:SessionManagerRefreshActive=$true
    try{
    $script:SessionManagerLastRefreshAt=Get-Date
    $selectedState=Get-SelectedSessionManagerState;$selectedId=if($null-ne$selectedState){[string](Get-UiConfigValue $selectedState 'RowKey' '')}else{''}
    $rowsById=@{};$existingStatesById=@{};foreach($row in @($script:SessionManagerGrid.Rows)){if($null-ne$row.Tag){$existingRowKey=[string](Get-UiConfigValue $row.Tag 'RowKey' '');if(-not[string]::IsNullOrWhiteSpace($existingRowKey)){$rowsById[$existingRowKey]=$row;$existingStatesById[$existingRowKey]=$row.Tag}}}
    $states=New-Object System.Collections.ArrayList
    foreach($project in @($script:Projects)){
        $projectSessions=@(Get-ProjectCodexSessions $project)
        if($projectSessions.Count-eq0){[void]$states.Add((Get-ProjectSessionManagerState $project $null -SessionIndex -1 -ExistingStatesById $existingStatesById))}
        else{for($sessionIndex=0;$sessionIndex-lt$projectSessions.Count;$sessionIndex++){[void]$states.Add((Get-ProjectSessionManagerState $project $projectSessions[$sessionIndex] -SessionIndex $sessionIndex -ExistingStatesById $existingStatesById))}}
    }
    $states=@($states|Sort-Object @{Expression={$_.SortTime};Descending=$true},@{Expression={$_.ProjectName};Descending=$false},@{Expression={$_.Description};Descending=$false})
    $currentOrder=New-Object 'System.Collections.Generic.List[string]';foreach($existingRow in @($script:SessionManagerGrid.Rows)){[void]$currentOrder.Add([string](Get-UiConfigValue $existingRow.Tag 'RowKey' ''))}
    $desiredOrder=New-Object 'System.Collections.Generic.List[string]';foreach($desiredState in $states){[void]$desiredOrder.Add([string]$desiredState.RowKey)}
    if(($currentOrder-join"`n")-ne($desiredOrder-join"`n")){$script:SessionManagerGrid.Rows.Clear();$rowsById=@{}}
    $stateIds=@{};foreach($state in $states){$stateIds[[string]$state.RowKey]=$true}
    for($index=$script:SessionManagerGrid.Rows.Count-1;$index-ge0;$index--){$existingRow=Get-UiIndexedItemSafe $script:SessionManagerGrid.Rows $index;if($null-ne$existingRow-and-not$stateIds.ContainsKey([string](Get-UiConfigValue $existingRow.Tag 'RowKey' ''))){$script:SessionManagerGrid.Rows.RemoveAt($index)}}
    foreach($state in $states){
        $rowKey=[string]$state.RowKey
        if($rowsById.ContainsKey($rowKey)){$row=$rowsById[$rowKey]}else{$rowIndex=$script:SessionManagerGrid.Rows.Add();$row=Get-UiIndexedItemSafe $script:SessionManagerGrid.Rows $rowIndex}
        if($null-eq$row){continue}
        if(-not[object]::ReferenceEquals($row.Tag,$state)){$row.Tag=$state}
        $updatedText='';if(-not[string]::IsNullOrWhiteSpace([string]$state.UpdatedAt)){try{$updatedText=([datetime]$state.UpdatedAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')}catch{$updatedText=[string]$state.UpdatedAt}}
        $values=@([string]$state.ProjectName,[string]$state.Status,[string]$state.Description,[string]$state.SessionId,[string]$state.Model,[string]$state.WorkingDirectory,$updatedText)
        for($cellIndex=0;$cellIndex-lt$values.Count;$cellIndex++){$cell=Get-UiIndexedItemSafe $row.Cells $cellIndex;if($null-ne$cell-and[string]$cell.Value-ne[string]$values[$cellIndex]){$cell.Value=$values[$cellIndex]}}
    }
    if(-not[string]::IsNullOrWhiteSpace($selectedId)){$selectedRow=$null;foreach($candidateRow in @($script:SessionManagerGrid.Rows)){if([string](Get-UiConfigValue $candidateRow.Tag 'RowKey' '')-eq$selectedId){$selectedRow=$candidateRow;break}};if($null-ne$selectedRow){$firstCell=Get-UiIndexedItemSafe $selectedRow.Cells 0;$selectedRow.Selected=$true;if($null-ne$firstCell){$script:SessionManagerGrid.CurrentCell=$firstCell}}}
    elseif($script:SessionManagerGrid.Rows.Count-gt0-and$script:SessionManagerGrid.SelectedRows.Count-eq0){$firstRow=Get-UiIndexedItemSafe $script:SessionManagerGrid.Rows 0;if($null-ne$firstRow){$firstCell=Get-UiIndexedItemSafe $firstRow.Cells 0;$firstRow.Selected=$true;if($null-ne$firstCell){$script:SessionManagerGrid.CurrentCell=$firstCell}}}
    if($null-ne$script:SessionManagerOpenButton){$script:SessionManagerOpenButton.Enabled=-not[string]::IsNullOrWhiteSpace((Get-SelectedSessionManagerProjectId))}
    }finally{$script:SessionManagerRefreshActive=$false}
}

function Open-SelectedManagedSession {
    $state=Get-SelectedSessionManagerState;if($null-eq$state){return}
    $projectId=[string](Get-UiConfigValue $state 'ProjectId' '');if([string]::IsNullOrWhiteSpace($projectId)){return}
    $sessionId=[string](Get-UiConfigValue $state 'SessionId' '')
    $project=Get-ProjectById $projectId;if($null-eq$project){return}
    $selectedSession=[pscustomobject]@{SessionId=$sessionId;CodexModel=[string](Get-UiConfigValue $state 'Model' '');Description=[string](Get-UiConfigValue $state 'Description' '无描述')}
    $script:BindingWorkflow=$true
    try{
        for($index=0;$index-lt$script:ProjectSelector.Items.Count;$index++){if([string]$script:ProjectSelector.Items[$index].Id-eq$projectId){$script:ProjectSelector.SelectedIndex=$index;break}}
        $script:CurrentProject=$project;Update-ProjectInfo;Refresh-WorkflowList
    }finally{$script:BindingWorkflow=$false}
    Show-ProjectConversation -SessionId $sessionId -UseSelectedSession -SelectedSession $selectedSession
}

function Show-SessionManagerPage {
    if($null-ne$script:CodexConversationPanel){$script:CodexConversationPanel.Visible=$false}
    if($null-ne$script:RunningTasksPanel){$script:RunningTasksPanel.Visible=$false}
    Hide-EmbeddedCommonPromptsPanel
    if($null-ne$script:WorkflowSettingsPanel){$script:WorkflowSettingsPanel.Visible=$false}
    if($null-ne$script:WorkflowLogPanel){$script:WorkflowLogPanel.Visible=$false}
    if($null-ne$script:Canvas){$script:Canvas.Visible=$false}
    if($null-ne$script:SessionManagerPanel){$script:SessionManagerPanel.Visible=$true;$script:SessionManagerPanel.BringToFront()}
    Refresh-SessionManagerView -Force
}

function Get-CurrentCodexConversationProcessKey {
    if($script:CodexConversationMode-eq'Project'){
        $project=Get-ProjectById $script:CodexConversationProjectId;$index=-1
        if($null-ne$project){$sessions=@(Get-ProjectCodexSessions $project);for($i=0;$i-lt$sessions.Count;$i++){if([string]$sessions[$i].SessionId-eq[string]$script:CodexConversationSessionId-and[string]$sessions[$i].Description-eq[string]$script:CodexConversationSessionDescription){$index=$i;break}}}
        return Get-CodexConversationProcessKey $script:CodexConversationMode $script:CodexConversationProjectId $script:CodexConversationSessionId $index
    }
    return Get-CodexConversationProcessKey $script:CodexConversationMode $script:CodexConversationProjectId $script:CodexConversationSessionId
}

function Update-CodexConversationControls {
    $key = Get-CurrentCodexConversationProcessKey
    $running = Test-CodexConversationProcessRunning $key
    $conversationBusy = Test-CodexConversationProcessBusy $key
    $busyWorkflow = $null
    if ($script:CodexConversationMode -eq 'Project' -and -not [string]::IsNullOrWhiteSpace($script:CodexConversationProjectId)) {
        $busyWorkflow = Get-ProjectCodexSessionBusyRecord (Get-ProjectById $script:CodexConversationProjectId) $script:CodexConversationSessionId
    }
    $blocked = $conversationBusy -or $null -ne $busyWorkflow
    if ($null -ne $script:CodexConversationSend) { $script:CodexConversationSend.Enabled = -not $blocked }
    if ($null -ne $script:CodexConversationInput) { $script:CodexConversationInput.Enabled = -not $blocked }
    if ($null -ne $script:CodexConversationAttachButton) { $script:CodexConversationAttachButton.Enabled = -not $blocked }
    if ($null -ne $script:CodexConversationClearAttachmentsButton) { $script:CodexConversationClearAttachmentsButton.Enabled = -not $blocked -and $script:CodexConversationPendingImages.Count -gt 0 }
    if ($null -ne $script:CodexConversationStopButton) { $script:CodexConversationStopButton.Enabled = $running }
    if ($running) { Set-CodexConversationStatus '会话后台执行中 · 可切换项目或工作任务' 'Busy' }
    elseif ($conversationBusy) { Set-CodexConversationStatus 'Codex 已退出，正在同步回复...' 'Busy' }
    elseif ($null -ne $busyWorkflow) { Set-CodexConversationStatus ('该会话正在由工作任务“' + [string]$busyWorkflow.WorkflowName + '”调用，节点完成后可继续发送') 'Busy' }
}

function Stop-CurrentCodexConversation {
    $key=Get-CurrentCodexConversationProcessKey
    if([string]::IsNullOrWhiteSpace($key)-or-not$script:CodexConversationProcesses.ContainsKey($key)){return $false}
    $record=$script:CodexConversationProcesses[$key]
    if($null-eq$record){return $false}
    try{if($record.Process.HasExited){Complete-ProjectCodexMessage;return $true}}catch{return $false}
    if($null-eq$record.PSObject.Properties['StopRequested']){$record|Add-Member NoteProperty StopRequested $true}else{$record.StopRequested=$true}
    if($null-eq$record.PSObject.Properties['TerminationReason']){$record|Add-Member NoteProperty TerminationReason 'ManualStop'}else{$record.TerminationReason='ManualStop'}
    if($null-ne$script:CodexConversationStopButton){$script:CodexConversationStopButton.Enabled=$false}
    Set-CodexConversationStatus '正在停止会话...' 'Busy'
    try{
        Stop-WorkflowProcessTree ([int]$record.Process.Id)
        return $true
    }catch{
        $record.StopRequested=$false
        Set-CodexConversationStatus ('停止会话失败：'+$_.Exception.Message) 'Error'
        Update-CodexConversationControls
        return $false
    }
}

function Add-CodexMessageToSnapshot {
    param([string]$SessionId, [string]$Role, [string]$Text, [switch]$SkipIfLast)
    if ([string]::IsNullOrWhiteSpace($SessionId) -or [string]::IsNullOrWhiteSpace($Text) -or -not $script:CodexConversationSnapshots.ContainsKey($SessionId)) { return }
    $snapshot = $script:CodexConversationSnapshots[$SessionId]
    $messages = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($snapshot.Messages)) { $messages.Add($message) }
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($message in @(Get-UiConfigValue $snapshot 'PendingMessages' @())) { $pending.Add($message) }
    $last = if ($messages.Count -gt 0) { $messages[$messages.Count - 1] } else { $null }
    if ($SkipIfLast -and $null -ne $last -and [string]$last.Role -eq $Role -and [string]$last.Text -eq $Text) { return }
    $localMessage = [pscustomobject]@{ Role=$Role; Text=$Text; Time=(Get-Date).ToUniversalTime().ToString('o') }
    $messages.Add($localMessage)
    $pending.Add([pscustomobject]@{ Role=$Role; Text=$Text })
    while ($messages.Count -gt $script:CodexConversationSnapshotMaxMessages) { $messages.RemoveAt(0) }
    while ($pending.Count -gt 32) { $pending.RemoveAt(0) }
    for ($messageIndex = 0; $messageIndex -lt $messages.Count; $messageIndex++) {
        $message = $messages[$messageIndex]
        $messageText = [string](Get-UiConfigValue $message 'Text' '')
        if ($messageText.Length -gt $script:CodexConversationSnapshotMaxMessageCharacters) {
            $keepLength = [Math]::Max(1000, $script:CodexConversationSnapshotMaxMessageCharacters - 96)
            $messages[$messageIndex] = [pscustomobject]@{
                Role = [string](Get-UiConfigValue $message 'Role' 'assistant')
                Text = "[消息过长，已裁剪，仅保留末尾内容]`r`n" + $messageText.Substring([Math]::Max(0, $messageText.Length - $keepLength))
                Time = [string](Get-UiConfigValue $message 'Time' '')
            }
        }
    }
    Trim-CodexConversationMessageLists -Messages (,$messages) -Pending (,$pending) -MaximumCharacters $script:CodexConversationSnapshotMaxCharactersPerSession
    $snapshot.Messages = $messages.ToArray()
    if ($null -eq $snapshot.PSObject.Properties['PendingMessages']) { $snapshot | Add-Member -NotePropertyName PendingMessages -NotePropertyValue $pending.ToArray() }
    else { $snapshot.PendingMessages = $pending.ToArray() }
    $snapshot.UpdatedAt = Get-Date
    $script:CodexConversationSnapshotAccess[$SessionId] = Get-Date
    if ($script:CodexConversationSnapshots.Count -gt $script:CodexConversationSnapshotMaxCount) { Invoke-WorkflowMemoryMaintenance -Force }
}

function Reset-CodexConversationOutput {
    Reset-CodexConversationSearchState
    $script:CodexConversationScrollGeneration++
    $script:CodexConversationScrollPending=$false
    $script:CodexConversationMouseWheelScrollPending=$false
    $script:CodexConversationRecordScrollPending=$false
    $script:CodexConversationRecordScrollRecord=$null
    $script:CodexConversationResizeInProgress=$false
    $script:CodexConversationOutputLayoutWidth=0
    $script:CodexConversationOutputLayoutDpi=0
    $records=@($script:CodexConversationBubbleRecords)
    $script:CodexConversationRenderBox=$null
    $script:CodexConversationCurrentLinks=$null
    $script:CodexConversationCurrentBubble=$null
    if($null-ne$script:CodexConversationLinks){try{$script:CodexConversationLinks.Clear()}catch{}}
    foreach($record in $records){
        if($null-eq$record){continue}
        $font=$null
        try{
            if($null-ne$record.Links){$record.Links.Clear()}
            if($null-ne$record.TextBox){$record.TextBox.Tag=$null;$record.TextBox.ScrollHost=$null;$font=$record.TextBox.Font}
            if($null-ne$record.Row-and-not$record.Row.IsDisposed){$record.Row.Dispose()}
        }catch{}
        finally{if($null-ne$font){try{$font.Dispose()}catch{}}}
    }
    if($null-ne$script:CodexConversationOutput){
        $script:CodexConversationOutput.SuspendLayout()
        try{foreach($control in @($script:CodexConversationOutput.Controls)){$control.Dispose()};$script:CodexConversationOutput.Controls.Clear();$script:CodexConversationOutput.Text='';$script:CodexConversationOutput.AutoScrollMinSize=[Drawing.Size]::Empty;$script:CodexConversationOutput.AutoScrollPosition=New-Object Drawing.Point(0,0)}finally{$script:CodexConversationOutput.ResumeLayout($true)}
    }
    $script:CodexConversationUserMessagePositions=New-Object System.Collections.ArrayList
    $script:CodexConversationLinks=New-Object System.Collections.ArrayList
    $script:CodexConversationBubbleRecords=New-Object System.Collections.ArrayList
    $script:CodexConversationUserNavigationIndex=0
    $script:CodexConversationLastRole=''
    $script:CodexConversationActiveBackColor=[Drawing.Color]::FromArgb(248,250,252)
    $script:CodexConversationBottomSpacer=$null
    $script:CodexConversationTranscriptParts=New-Object System.Collections.ArrayList
}

function Commit-CodexConversationTranscript {
    if($null-eq$script:CodexConversationOutput-or$script:CodexConversationOutput.IsDisposed){return}
    $parts=@($script:CodexConversationTranscriptParts|ForEach-Object{[string]$_})
    $script:CodexConversationOutput.Text=if($parts.Count-eq0){''}else{$parts-join"`r`n`r`n"}
}

function Get-CodexConversationPlainText {
    param([string]$Text)
    if($null-eq$Text){return ''}
    $value=$Text-replace'\[(?<label>[^\]]+)\]\([^)]+\)','$1'
    $value=$value-replace'[*_`#>]',''
    return $value
}

function Get-CodexConversationDesiredWidth {
    param([string]$Text,[string]$Role)
    $listWidth=if($null-ne$script:CodexConversationOutput){[Math]::Max(360,$script:CodexConversationOutput.ClientSize.Width-$script:CodexConversationOutput.Padding.Horizontal-24)}else{720}
    $ratio=if($Role-eq'user'){0.76}else{0.86}
    $maximum=[Math]::Max(280,[Math]::Min(860,[int]($listWidth*$ratio)))
    $plain=Get-CodexConversationPlainText $Text
    $font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    try{
        $longest=0
        foreach($line in @(($plain-replace"`r`n","`n"-replace"`r","`n")-split"`n",-1)){
            $width=[Windows.Forms.TextRenderer]::MeasureText($(if([string]::IsNullOrEmpty($line)){' '}else{$line}),$font,(New-Object Drawing.Size(2000,40)),[Windows.Forms.TextFormatFlags]::NoPadding).Width
            if($width-gt$longest){$longest=$width}
        }
    }finally{$font.Dispose()}
    if($plain.Length-gt100-or$longest+54-ge$maximum){return [pscustomobject]@{Width=$maximum;ExpandToMaximum=$true}}
    return [pscustomobject]@{Width=[Math]::Max(220,[Math]::Min($maximum,$longest+54));ExpandToMaximum=$false}
}

function Resize-CodexConversationBubbleRecord {
    param($Record)
    if($null-eq$Record-or$null-eq$script:CodexConversationOutput-or$Record.Row.IsDisposed){return $false}
    $list=$script:CodexConversationOutput
    $rowWidth=[Math]::Max(280,$list.ClientSize.Width-$list.Padding.Horizontal-24)
    $ratio=if([string]$Record.Role-eq'user'){0.76}else{0.86}
    $maximum=[Math]::Max(280,[Math]::Min(860,[int]($rowWidth*$ratio)))
    $bubbleWidth=if([bool]$Record.ExpandToMaximum){$maximum}else{[Math]::Min($maximum,[Math]::Max(220,[int]$Record.DesiredWidth))}
    $textWidth=[Math]::Max(120,$bubbleWidth-$Record.Bubble.Padding.Horizontal)
    $dpi=Get-CurrentWorkflowDpi
    $textLength=[int]$Record.TextBox.TextLength
    $rtfLength=if($textLength-gt0){[int]$Record.TextBox.Rtf.Length}else{0}
    $layoutKey=($dpi.ToString()+'|'+$rowWidth+'|'+$bubbleWidth+'|'+$textWidth+'|'+$textLength+'|'+$rtfLength)
    if([string]$Record.LayoutKey-eq$layoutKey-and$Record.Row.Width-eq$rowWidth-and$Record.Bubble.Width-eq$bubbleWidth-and$Record.TextBox.Width-eq$textWidth-and$Record.TextBox.Height-eq[int]$Record.ContentHeight){return $false}
    if($Record.Row.Width-ne$rowWidth){$Record.Row.Width=$rowWidth}
    if($Record.Bubble.Width-ne$bubbleWidth){$Record.Bubble.Width=$bubbleWidth}
    $bubbleLeft=if([string]$Record.Role-eq'user'){[Math]::Max(4,$rowWidth-$bubbleWidth-4)}else{4}
    if($Record.Bubble.Left-ne$bubbleLeft){$Record.Bubble.Left=$bubbleLeft}
    if($Record.Bubble.Top-ne1){$Record.Bubble.Top=1}
    $Record.TextBox.Dock=[Windows.Forms.DockStyle]::None
    $textLocation=New-Object Drawing.Point($Record.Bubble.Padding.Left,$Record.Bubble.Padding.Top)
    if($Record.TextBox.Location-ne$textLocation){$Record.TextBox.Location=$textLocation}
    if($Record.TextBox.Width-ne$textWidth){$Record.TextBox.Width=$textWidth}
    $contentHeight=30
    if($Record.TextBox.TextLength-gt0){
        $measureFlags=[Windows.Forms.TextFormatFlags]::WordBreak-bor[Windows.Forms.TextFormatFlags]::TextBoxControl-bor[Windows.Forms.TextFormatFlags]::NoPadding
        $measured=[Windows.Forms.TextRenderer]::MeasureText($Record.TextBox.Text,$Record.TextBox.Font,(New-Object Drawing.Size($textWidth,20000)),$measureFlags)
        $measurementHeight=[Math]::Max(80,[Math]::Min(20000,$measured.Height+(ConvertTo-WorkflowDpiPixels 180 120)))
        if($Record.TextBox.Height-ne$measurementHeight){$Record.TextBox.Height=$measurementHeight}
        $Record.TextBox.CreateControl()
        [WorkflowNativeMethods]::ScrollRichTextToTop($Record.TextBox)
        $visualLineCount=0
        try{$visualLineCount=[WorkflowNativeMethods]::GetRichTextLineCount($Record.TextBox)}catch{}
        $lineHeight=[Math]::Max(18,[int]$Record.TextBox.Font.Height+3)
        $visualHeight=if($visualLineCount-gt0){($visualLineCount*$lineHeight)+14}else{0}
        $positionHeight=0;$selectionStart=$Record.TextBox.SelectionStart;$selectionLength=$Record.TextBox.SelectionLength
        try{
            $lastCharacterIndex=$Record.TextBox.TextLength-1
            $lastCharacterPosition=$Record.TextBox.GetPositionFromCharIndex($lastCharacterIndex)
            $Record.TextBox.SelectionStart=$lastCharacterIndex;$Record.TextBox.SelectionLength=1
            $lastFontHeight=if($null-ne$Record.TextBox.SelectionFont){$Record.TextBox.SelectionFont.Height}else{$Record.TextBox.Font.Height}
            $positionHeight=$lastCharacterPosition.Y+$lastFontHeight+10
        }finally{$Record.TextBox.SelectionStart=[Math]::Min($selectionStart,$Record.TextBox.TextLength);$Record.TextBox.SelectionLength=[Math]::Min($selectionLength,[Math]::Max(0,$Record.TextBox.TextLength-$Record.TextBox.SelectionStart))}
        $contentHeight=[Math]::Max(30,[Math]::Min(20000,[Math]::Max($positionHeight,[Math]::Max($measured.Height+10,$visualHeight))))
    }
    if($Record.TextBox.Height-ne$contentHeight){$Record.TextBox.Height=$contentHeight}
    [WorkflowNativeMethods]::ScrollRichTextToTop($Record.TextBox)
    $bubbleHeight=$Record.Bubble.Padding.Vertical+$contentHeight
    if($Record.Bubble.Height-ne$bubbleHeight){$Record.Bubble.Height=$bubbleHeight}
    $rowHeight=$bubbleHeight+2
    if($Record.Row.Height-ne$rowHeight){$Record.Row.Height=$rowHeight}
    $Record.ContentHeight=$contentHeight
    $Record.LayoutKey=$layoutKey
    return $true
}

function Invoke-CodexConversationDeferredMouseWheelScroll {
    $script:CodexConversationMouseWheelScrollPending=$false
    $output=$script:CodexConversationOutput
    if($null-eq$output-or$output.IsDisposed){return}
    $maximum=[Math]::Max(0,$output.DisplayRectangle.Height-$output.ClientSize.Height)
    $target=[Math]::Min($maximum,[Math]::Max(0,[int]$script:CodexConversationMouseWheelTargetY))
    $output.AutoScrollPosition=New-Object Drawing.Point(0,$target)
}

function Scroll-CodexConversationFromMouseWheel {
    param([int]$Delta,[int]$LineHeight=18)
    $output=$script:CodexConversationOutput
    if($null-eq$output-or$output.IsDisposed-or$Delta-eq0){return $false}
    $script:CodexConversationScrollGeneration++
    $script:CodexConversationScrollPending=$false
    $currentY=[Math]::Max(0,-$output.AutoScrollPosition.Y)
    $maximum=[Math]::Max(0,$output.DisplayRectangle.Height-$output.ClientSize.Height)
    $scrollLines=[Windows.Forms.SystemInformation]::MouseWheelScrollLines
    if($scrollLines-lt1-or$scrollLines-gt20){$scrollLines=3}
    $wheelSteps=[Math]::Max(1,[Math]::Abs($Delta)/120)
    $distance=[int]($wheelSteps*$scrollLines*[Math]::Max(16,$LineHeight))
    $targetY=if($Delta-gt0){[Math]::Max(0,$currentY-$distance)}else{[Math]::Min($maximum,$currentY+$distance)}
    $output.AutoScrollPosition=New-Object Drawing.Point(0,$targetY)
    if($output.IsHandleCreated){
        $script:CodexConversationMouseWheelTargetY=$targetY
        try{
            if($null-eq$script:CodexConversationMouseWheelCallback){$script:CodexConversationMouseWheelCallback=[Action]{Invoke-CodexConversationDeferredMouseWheelScroll}}
            if(-not$script:CodexConversationMouseWheelScrollPending){$script:CodexConversationMouseWheelScrollPending=$true;[void]$output.BeginInvoke($script:CodexConversationMouseWheelCallback)}
        }catch{$script:CodexConversationMouseWheelScrollPending=$false}
    }
    return $true
}

function Ensure-CodexConversationBottomSpacer {
    $output=$script:CodexConversationOutput
    if($null-eq$output-or$output.IsDisposed){return $null}
    $spacer=$script:CodexConversationBottomSpacer
    if($null-eq$spacer-or$spacer.IsDisposed-or$spacer.Parent-ne$output){
        $spacer=New-Object Windows.Forms.Panel
        $spacer.Name='CodexConversationBottomSpacer'
        $spacer.Width=1
        $spacer.Height=30
        $spacer.Margin=New-Object Windows.Forms.Padding(0)
        $spacer.BackColor=(Get-CodexConversationPalette).Surface
        $spacer.Enabled=$false
        $spacer.TabStop=$false
        $output.Controls.Add($spacer)
        $script:CodexConversationBottomSpacer=$spacer
    }
    if($output.Controls.Contains($spacer)){$output.Controls.SetChildIndex($spacer,$output.Controls.Count-1)}
    return $spacer
}

function Resize-CodexConversationBubbles {
    param([switch]$Force)
    if($null-eq$script:CodexConversationOutput-or$script:CodexConversationOutput.IsDisposed-or$script:CodexConversationResizeInProgress){return $false}
    $output=$script:CodexConversationOutput
    $layoutWidth=[int]$output.ClientSize.Width
    $layoutDpi=Get-CurrentWorkflowDpi
    if(-not$Force-and$layoutWidth-eq$script:CodexConversationOutputLayoutWidth-and$layoutDpi-eq$script:CodexConversationOutputLayoutDpi){return $false}
    $script:CodexConversationOutputLayoutWidth=$layoutWidth
    $script:CodexConversationOutputLayoutDpi=$layoutDpi
    if($Force){foreach($record in @($script:CodexConversationBubbleRecords)){if($null-ne$record){$record.LayoutKey=''}}}
    $previousY=[Math]::Max(0,-$output.AutoScrollPosition.Y)
    $previousMaximum=[Math]::Max(0,$output.DisplayRectangle.Height-$output.ClientSize.Height)
    $wasAtBottom=($previousMaximum-$previousY)-le8
    $script:CodexConversationResizeInProgress=$true
    $output.SuspendLayout()
    $changed=$false
    try{foreach($record in @($script:CodexConversationBubbleRecords)){if(Resize-CodexConversationBubbleRecord $record){$changed=$true}};[void](Ensure-CodexConversationBottomSpacer)}finally{$output.ResumeLayout($changed);$script:CodexConversationResizeInProgress=$false}
    if(-not$changed){return $false}
    $newMaximum=[Math]::Max(0,$output.DisplayRectangle.Height-$output.ClientSize.Height)
    $targetY=if($wasAtBottom){$newMaximum}else{[Math]::Min($previousY,$newMaximum)}
    $output.AutoScrollPosition=New-Object Drawing.Point(0,$targetY)
    return $true
}

function Scroll-CodexConversationToBottom {
    if($null-eq$script:CodexConversationOutput-or$script:CodexConversationOutput.IsDisposed){return}
    [void](Ensure-CodexConversationBottomSpacer)
    $script:CodexConversationOutput.PerformLayout()
    $maximum=[Math]::Max(0,$script:CodexConversationOutput.DisplayRectangle.Height-$script:CodexConversationOutput.ClientSize.Height)
    $script:CodexConversationOutput.AutoScrollPosition=New-Object Drawing.Point(0,$maximum)
}

function Schedule-CodexConversationScrollToBottom {
    if($null-eq$script:CodexConversationOutput-or$script:CodexConversationOutput.IsDisposed){return}
    if($script:CodexConversationScrollPending){return}
    $script:CodexConversationScrollPending=$true
    $script:CodexConversationBottomScrollGeneration=[int]$script:CodexConversationScrollGeneration
    try{
        if($null-eq$script:CodexConversationBottomScrollCallback){$script:CodexConversationBottomScrollCallback=[Action]{
            if([int]$script:CodexConversationBottomScrollGeneration-ne[int]$script:CodexConversationScrollGeneration){$script:CodexConversationScrollPending=$false;return}
            $script:CodexConversationScrollPending=$false
            if($null-ne$script:CodexConversationOutput-and-not$script:CodexConversationOutput.IsDisposed){Scroll-CodexConversationToBottom}
        }}
        [void]$script:CodexConversationOutput.BeginInvoke($script:CodexConversationBottomScrollCallback)
    }catch{$script:CodexConversationScrollPending=$false;Scroll-CodexConversationToBottom}
}

function Complete-CodexConversationBatchRender {
    param([switch]$ScrollToBottom)
    if($null-eq$script:CodexConversationOutput-or$script:CodexConversationOutput.IsDisposed){return}
    $script:CodexConversationOutput.SuspendLayout()
    $changed=$false
    try{
        foreach($record in @($script:CodexConversationBubbleRecords)){if(Resize-CodexConversationBubbleRecord $record){$changed=$true}}
        Commit-CodexConversationTranscript
        if($changed){$script:CodexConversationOutput.PerformLayout()}
    }finally{$script:CodexConversationOutput.ResumeLayout($changed)}
    if($ScrollToBottom){Scroll-CodexConversationToBottom;Schedule-CodexConversationScrollToBottom}
}

function Invoke-CodexConversationVisibleSurfaceRefresh {
    if($null-eq$script:CodexConversationPanel-or$script:CodexConversationPanel.IsDisposed){return}
    $force=[bool]$script:CodexConversationSurfaceForcePending
    $script:CodexConversationSurfaceForcePending=$false
    try{
        $script:CodexConversationPanel.PerformLayout()
        if($null-ne$script:CodexConversationSplit){$script:CodexConversationSplit.PerformLayout()}
        if($null-ne$script:CodexConversationLayout){$script:CodexConversationLayout.PerformLayout()}
        if($null-ne$script:CodexConversationHeader){$script:CodexConversationHeader.PerformLayout()}
        if($null-ne$script:CodexConversationOutputHost){$script:CodexConversationOutputHost.PerformLayout()}
        if($null-ne$script:CodexConversationOutput){
            $script:CodexConversationOutput.PerformLayout()
            if($force){
                $script:CodexConversationOutputLayoutWidth=0;$script:CodexConversationOutputLayoutDpi=0
                foreach($record in @($script:CodexConversationBubbleRecords)){if($null-ne$record){$record.LayoutKey=''}}
                [void](Resize-CodexConversationBubbles -Force)
            }else{[void](Resize-CodexConversationBubbles)}
            $script:CodexConversationOutput.PerformLayout()
        }
        if($script:CodexConversationPanel.Visible){
            $script:CodexConversationPanel.Invalidate($true);$script:CodexConversationPanel.Update()
            if($null-ne$script:CodexConversationOutput){$script:CodexConversationOutput.Invalidate($true);$script:CodexConversationOutput.Update()}
        }
    }catch{Write-WorkflowLog ('会话页面重绘失败：'+$_.Exception.Message) 'ERROR'}
}

function Invoke-CodexConversationDeferredSurfaceRefresh {
    $script:CodexConversationSurfaceRefreshPending=$false
    Invoke-CodexConversationVisibleSurfaceRefresh
}

function Refresh-CodexConversationVisibleSurface {
    param([switch]$ForceBubbleLayout,[switch]$Deferred)
    if($null-eq$script:CodexConversationPanel-or$script:CodexConversationPanel.IsDisposed-or$null-eq$script:CodexConversationOutput-or$script:CodexConversationOutput.IsDisposed){return $false}
    if($ForceBubbleLayout){$script:CodexConversationSurfaceForcePending=$true}
    Invoke-CodexConversationVisibleSurfaceRefresh
    if($Deferred){return $true}
    if($null-ne$script:MainForm-and-not$script:MainForm.IsDisposed-and$script:MainForm.IsHandleCreated-and-not$script:CodexConversationSurfaceRefreshPending){
        $script:CodexConversationSurfaceRefreshPending=$true
        try{
            if($null-eq$script:CodexConversationSurfaceRefreshCallback){$script:CodexConversationSurfaceRefreshCallback=[Action]{Invoke-CodexConversationDeferredSurfaceRefresh}}
            [void]$script:MainForm.BeginInvoke($script:CodexConversationSurfaceRefreshCallback)
        }catch{$script:CodexConversationSurfaceRefreshPending=$false}
    }
    return $true
}

function New-CodexConversationBubbleRecord {
    param([string]$Role,[string]$Text)
    $palette=Get-CodexConversationPalette
    $row=New-Object Windows.Forms.Panel;$row.Margin=New-Object Windows.Forms.Padding(0,0,0,12);$row.BackColor=$palette.Surface;$row.TabStop=$false
    $bubble=New-Object WorkflowRoundedPanel;$bubble.Padding=New-Object Windows.Forms.Padding(14,11,14,10);$bubble.CornerRadius=14;$bubble.BorderWidth=1
    $bubbleColor=if($Role-eq'user'){$palette.UserBubble}else{$palette.AssistantBubble};$bubble.FillColor=$bubbleColor;$bubble.BorderColor=[Windows.Forms.ControlPaint]::Dark($bubbleColor)
    $links=New-Object System.Collections.ArrayList
    $textBox=New-Object WorkflowConversationRichTextBox;$textBox.ScrollHost=$script:CodexConversationOutput;$textBox.ReadOnly=$true;$textBox.BorderStyle='None';$textBox.BackColor=$bubbleColor;$textBox.ForeColor=[Drawing.Color]::FromArgb(30,41,59);$textBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$textBox.DetectUrls=$false;$textBox.ScrollBars=[Windows.Forms.RichTextBoxScrollBars]::None;$textBox.WordWrap=$true;$textBox.HideSelection=$false;$textBox.AutoWordSelection=$false;$textBox.TabStop=$false;$textBox.AutoSize=$false
    $textBox.Tag=[pscustomobject]@{Links=$links;Role=$Role}
    $textBox.Add_MouseWheel({param($sender,$e);[void](Scroll-CodexConversationFromMouseWheel ([int]$e.Delta) ([Math]::Max(16,$sender.Font.Height)))})
    $textBox.Add_MouseClick({param($sender,$e);$controlPressed=(([Windows.Forms.Control]::ModifierKeys-band[Windows.Forms.Keys]::Control)-eq[Windows.Forms.Keys]::Control);if($e.Button-eq[Windows.Forms.MouseButtons]::Left-and$controlPressed){[void](Open-CodexConversationLinkAtPoint $sender $e.Location)}})
     $textBox.Add_MouseUp({
         param($sender,$e)
         if($e.Button-ne[Windows.Forms.MouseButtons]::Right){return}
         $index=-1
         try{$index=$sender.GetCharIndexFromPosition($e.Location)}catch{}
         $link=Get-CodexConversationLinkAtPoint $sender $e.Location
         if($null-eq$link){Write-WorkflowLog ('Conversation link right-click did not match a link; index='+[string]$index+'; point='+[string]$e.Location+'; textLength='+[string]$sender.TextLength) 'DEBUG';return}
         try{$resolved=Resolve-CodexConversationLinkTarget ([string]$link.Target)}catch{Write-WorkflowLog ('Conversation link right-click resolve failed; rawTarget='+[string]$link.Target+'; error='+$_.Exception.Message) 'ERROR';return}
         if([string]$resolved.Kind-notin@('TextDocument','Executable','DefaultFile')){Write-WorkflowLog ('Conversation link right-click is not a local file; rawTarget='+[string]$link.Target+'; kind='+[string]$resolved.Kind) 'DEBUG';return}
         if(-not[IO.File]::Exists([string]$resolved.Target)){Write-WorkflowLog ('Conversation link right-click resolved to a missing file; rawTarget='+[string]$link.Target+'; resolvedPath='+[string]$resolved.Target) 'ERROR';return}
         Write-WorkflowLog ('Conversation link right-click matched; rawTarget='+[string]$link.Target+'; resolvedPath='+[string]$resolved.Target+'; line='+[string]$resolved.Line) 'DEBUG'
         $script:CodexConversationLinkContext=[pscustomobject]@{Target=[string]$link.Target;Box=$sender;Point=$e.Location;Resolved=$resolved}
          try{$menu=Ensure-CodexConversationLinkContextMenu;$menu.Tag=$script:CodexConversationLinkContext;Write-WorkflowLog ('Conversation link context menu show requested; rawTarget='+[string]$link.Target) 'DEBUG';$menu.Show($sender,$e.Location)}catch{Write-WorkflowLog ('Conversation link context menu show failed; rawTarget='+[string]$link.Target+'; error='+$_.Exception.Message) 'ERROR'}
     })
    $bubble.Controls.Add($textBox);$row.Controls.Add($bubble);$script:CodexConversationOutput.Controls.Add($row);[void](Ensure-CodexConversationBottomSpacer)
    $widthInfo=Get-CodexConversationDesiredWidth $Text $Role
    $record=[pscustomobject]@{Role=$Role;Row=$row;Bubble=$bubble;TextBox=$textBox;Links=$links;DesiredWidth=[int]$widthInfo.Width;ExpandToMaximum=[bool]$widthInfo.ExpandToMaximum;LayoutKey='';ContentHeight=0}
    [void]$script:CodexConversationBubbleRecords.Add($record)
    if(-not[bool]$script:CodexConversationBatchRendering){[void](Resize-CodexConversationBubbleRecord $record)}
    return $record
}

function Get-CodexConversationTimeLabel {
    param([string]$Time)
    if ([string]::IsNullOrWhiteSpace($Time)) { return '' }
    try { return ([datetime]$Time).ToLocalTime().ToString('MM-dd HH:mm') } catch { return '' }
}

function Add-CodexRichTextSegment {
    param(
        [string]$Text,
        [Drawing.Color]$Color = ([Drawing.Color]::FromArgb(30,41,59)),
        [float]$Size = 10,
        [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular,
        [string]$FontFamily = 'Microsoft YaHei UI',
        [Drawing.Color]$BackColor = ([Drawing.Color]::Empty),
        [string]$LinkTarget = ''
    )
    if($null-eq$script:CodexConversationRenderBox-or[string]::IsNullOrEmpty($Text)){return}
    $box=$script:CodexConversationRenderBox;$start=$box.TextLength;$font=New-Object Drawing.Font($FontFamily,$Size,$Style)
    $resolvedBackColor=if($BackColor.IsEmpty){$script:CodexConversationActiveBackColor}else{$BackColor}
    try{$box.SelectionStart=$start;$box.SelectionLength=0;$box.SelectionFont=$font;$box.SelectionColor=$Color;$box.SelectionBackColor=$resolvedBackColor;$box.AppendText($Text)}finally{$font.Dispose()}
    if(-not[string]::IsNullOrWhiteSpace($LinkTarget)){
        $linkRecord=[pscustomobject]@{Box=$box;Start=$start;Length=$Text.Length;Target=$LinkTarget}
        if($null-ne$script:CodexConversationCurrentLinks){[void]$script:CodexConversationCurrentLinks.Add($linkRecord)}
        [void]$script:CodexConversationLinks.Add($linkRecord)
    }
}

function Add-CodexInlineMarkdown {
    param([string]$Text,[float]$Size=10,[Drawing.FontStyle]$BaseStyle=[Drawing.FontStyle]::Regular,[Drawing.Color]$Color=([Drawing.Color]::FromArgb(30,41,59)))
    if($null-eq$Text){return}
    $pattern='\[(?<label>[^\]]+)\]\((?<target>[^)]+)\)|\*\*(?<bold>.+?)\*\*|`(?<code>[^`\r\n]+)`|(?<url>https?://[^\s<>]+)'
    $cursor=0
    foreach($match in [regex]::Matches($Text,$pattern)){
        if($match.Index-gt$cursor){Add-CodexRichTextSegment $Text.Substring($cursor,$match.Index-$cursor) $Color $Size $BaseStyle}
        if($match.Groups['label'].Success){
            Add-CodexRichTextSegment ([string]$match.Groups['label'].Value) ([Drawing.Color]::FromArgb(37,99,235)) $Size ([Drawing.FontStyle]::Underline) 'Microsoft YaHei UI' ([Drawing.Color]::Empty) ([string]$match.Groups['target'].Value)
        }elseif($match.Groups['bold'].Success){
            Add-CodexRichTextSegment ([string]$match.Groups['bold'].Value) $Color $Size ([Drawing.FontStyle]::Bold)
        }elseif($match.Groups['code'].Success){
            Add-CodexRichTextSegment (' '+[string]$match.Groups['code'].Value+' ') ([Drawing.Color]::FromArgb(190,24,93)) 9.5 ([Drawing.FontStyle]::Regular) 'Consolas'
        }else{
            $url=[string]$match.Groups['url'].Value;Add-CodexRichTextSegment $url ([Drawing.Color]::FromArgb(37,99,235)) $Size ([Drawing.FontStyle]::Underline) 'Microsoft YaHei UI' ([Drawing.Color]::Empty) $url
        }
        $cursor=$match.Index+$match.Length
    }
    if($cursor-lt$Text.Length){Add-CodexRichTextSegment $Text.Substring($cursor) $Color $Size $BaseStyle}
}

function Add-CodexMarkdownText {
    param([string]$Text)
    $normalized=($Text-replace"`r`n","`n"-replace"`r","`n").Trim()
    $inCodeBlock=$false
    $renderedLineCount=0
    foreach($line in @($normalized-split"`n",-1)){
        if($line-match'^\s*```'){$inCodeBlock=-not$inCodeBlock;continue}
        if($renderedLineCount-gt0){Add-CodexRichTextSegment "`r`n"}
        $renderedLineCount++
        if($inCodeBlock){Add-CodexRichTextSegment $line ([Drawing.Color]::FromArgb(51,65,85)) 9.3 ([Drawing.FontStyle]::Regular) 'Consolas';continue}
        if($line-match'^(#{1,3})\s+(.+)$'){
            $level=$matches[1].Length;$size=if($level-eq1){14}elseif($level-eq2){12.5}else{11.5};Add-CodexInlineMarkdown ([string]$matches[2]) $size ([Drawing.FontStyle]::Bold) ([Drawing.Color]::FromArgb(15,23,42));continue
        }
        if($line-match'^\s*[-*+]\s+(.+)$'){Add-CodexRichTextSegment '  • ' ([Drawing.Color]::FromArgb(71,85,105));Add-CodexInlineMarkdown ([string]$matches[1]);continue}
        if($line-match'^\s*(\d+)\.\s+(.+)$'){Add-CodexRichTextSegment ('  '+$matches[1]+'. ') ([Drawing.Color]::FromArgb(71,85,105));Add-CodexInlineMarkdown ([string]$matches[2]);continue}
        if($line-match'^\s*>\s?(.*)$'){Add-CodexRichTextSegment '  │ ' ([Drawing.Color]::FromArgb(148,163,184));Add-CodexInlineMarkdown ([string]$matches[1]) 10 ([Drawing.FontStyle]::Italic) ([Drawing.Color]::FromArgb(71,85,105));continue}
        if($line-match'^\s*([-*_])\1\1+\s*$'){Add-CodexRichTextSegment ('─'*50) ([Drawing.Color]::FromArgb(203,213,225)) 9;continue}
        Add-CodexInlineMarkdown $line
    }
}

function Move-CodexConversationInputCaretAtBoundary {
    param(
        [Windows.Forms.TextBoxBase]$TextBox,
        [Windows.Forms.Keys]$KeyCode
    )
    if ($null -eq $TextBox -or $TextBox.IsDisposed -or $TextBox.SelectionLength -ne 0) { return $false }
    $currentLine = $TextBox.GetLineFromCharIndex($TextBox.SelectionStart)
    if ($KeyCode -eq [Windows.Forms.Keys]::Down) {
        $lastLine = $TextBox.GetLineFromCharIndex($TextBox.TextLength)
        if ($currentLine -eq $lastLine -and $TextBox.SelectionStart -lt $TextBox.TextLength) {
            $TextBox.SelectionStart = $TextBox.TextLength
            $TextBox.SelectionLength = 0
            return $true
        }
    }
    if ($KeyCode -eq [Windows.Forms.Keys]::Up -and $currentLine -eq 0 -and $TextBox.SelectionStart -gt 0) {
        $TextBox.SelectionStart = 0
        $TextBox.SelectionLength = 0
        return $true
    }
    return $false
}

function Invoke-CodexConversationDeferredRecordScroll {
    $script:CodexConversationRecordScrollPending=$false
    $output=$script:CodexConversationOutput
    $record=$script:CodexConversationRecordScrollRecord
    $target=[int]$script:CodexConversationRecordScrollTargetY
    $preserveFocus=[bool]$script:CodexConversationRecordScrollPreserveFocus
    $script:CodexConversationRecordScrollRecord=$null
    if($null-eq$output-or$output.IsDisposed){return}
    $output.PerformLayout()
    $maximum=[Math]::Max(0,$output.DisplayRectangle.Height-$output.ClientSize.Height)
    $target=[Math]::Min($maximum,[Math]::Max(0,$target))
    $output.AutoScrollPosition=New-Object Drawing.Point(0,$target)
    if(-not$preserveFocus-and$null-ne$record-and$null-ne$record.TextBox-and-not$record.TextBox.IsDisposed){[void]$record.TextBox.Focus();$output.AutoScrollPosition=New-Object Drawing.Point(0,$target)}
}

function Scroll-CodexConversationRecordIntoView {
    param($Record, [switch]$PreserveFocus, [int]$CharacterIndex = -1)
    $output = $script:CodexConversationOutput
    if ($null -eq $output -or $output.IsDisposed -or $null -eq $Record -or $null -eq $Record.Row -or $Record.Row.IsDisposed) { return $false }
    $script:CodexConversationScrollGeneration++
    $script:CodexConversationScrollPending=$false
    $output.PerformLayout()
    $currentY = [Math]::Max(0, -$output.AutoScrollPosition.Y)
    $logicalTop = $currentY + [int]$Record.Row.Top
    if ($CharacterIndex -ge 0 -and $null -ne $Record.TextBox -and -not $Record.TextBox.IsDisposed -and $Record.TextBox.TextLength -gt 0) {
        $safeCharacterIndex = [Math]::Min($CharacterIndex, $Record.TextBox.TextLength - 1)
        $characterPosition = $Record.TextBox.GetPositionFromCharIndex($safeCharacterIndex)
        $logicalTop += [int]$Record.TextBox.Top + [int]$characterPosition.Y
    }
    $maximum = [Math]::Max(0, $output.DisplayRectangle.Height - $output.ClientSize.Height)
    $targetY = [Math]::Min($maximum, [Math]::Max(0, $logicalTop - 10))
    $output.AutoScrollPosition = New-Object Drawing.Point(0, $targetY)
    if (-not $PreserveFocus -and $null -ne $Record.TextBox -and -not $Record.TextBox.IsDisposed) { [void]$Record.TextBox.Focus() }
    $output.AutoScrollPosition = New-Object Drawing.Point(0, $targetY)
    if ($output.IsHandleCreated) {
        try {
            $script:CodexConversationRecordScrollTargetY=$targetY
            $script:CodexConversationRecordScrollRecord=$Record
            $script:CodexConversationRecordScrollPreserveFocus=[bool]$PreserveFocus
            if($null-eq$script:CodexConversationRecordScrollCallback){$script:CodexConversationRecordScrollCallback=[Action]{Invoke-CodexConversationDeferredRecordScroll}}
            if(-not$script:CodexConversationRecordScrollPending){$script:CodexConversationRecordScrollPending=$true;[void]$output.BeginInvoke($script:CodexConversationRecordScrollCallback)}
        } catch { }
    }
    return $true
}

function Clear-CodexConversationSearchSelection {
    $record = $script:CodexConversationSearchSelectedRecord
    if ($null -ne $record -and $null -ne $record.TextBox -and -not $record.TextBox.IsDisposed) { $record.TextBox.SelectionLength = 0 }
    $script:CodexConversationSearchSelectedRecord = $null
}

function Reset-CodexConversationSearchState {
    param([switch]$ClearText)
    Clear-CodexConversationSearchSelection
    $script:CodexConversationSearchQuery = ''
    $script:CodexConversationSearchMatches = @()
    $script:CodexConversationSearchIndex = -1
    $script:CodexConversationSearchSignature = ''
    if ($ClearText -and $null -ne $script:CodexConversationSearchBox -and -not $script:CodexConversationSearchBox.IsDisposed) { $script:CodexConversationSearchBox.Clear() }
}

function Get-CodexConversationSearchSignature {
    $records = @($script:CodexConversationBubbleRecords)
    $totalLength = [long]0
    foreach ($record in $records) {
        if ($null -ne $record -and $null -ne $record.TextBox -and -not $record.TextBox.IsDisposed) { $totalLength += [long]$record.TextBox.TextLength }
    }
    return ([string]$records.Count + ':' + [string]$totalLength)
}

function Get-CodexConversationRenderedTextLength {
    $totalLength = [long]0
    foreach ($record in @($script:CodexConversationBubbleRecords)) {
        if ($null -ne $record -and $null -ne $record.TextBox -and -not $record.TextBox.IsDisposed) {
            $totalLength += [long]$record.TextBox.TextLength
        }
    }
    return $totalLength
}

function Find-PreviousCodexConversationText {
    param([string]$Query = '')
    if ([string]::IsNullOrWhiteSpace($Query) -and $null -ne $script:CodexConversationSearchBox) { $Query = [string]$script:CodexConversationSearchBox.Text }
    $Query = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($Query)) { Set-CodexConversationStatus '请输入要查找的文本' 'Error'; return $false }
    $signature = Get-CodexConversationSearchSignature
    $queryChanged = -not [string]::Equals($script:CodexConversationSearchQuery, $Query, [StringComparison]::OrdinalIgnoreCase)
    if ($queryChanged -or $script:CodexConversationSearchSignature -ne $signature) {
        Clear-CodexConversationSearchSelection
        $matches = New-Object System.Collections.ArrayList
        $records = @($script:CodexConversationBubbleRecords)
        for ($recordIndex = $records.Count - 1; $recordIndex -ge 0; $recordIndex--) {
            $record = $records[$recordIndex]
            if ($null -eq $record -or $null -eq $record.TextBox -or $record.TextBox.IsDisposed) { continue }
            $recordMatches = [regex]::Matches([string]$record.TextBox.Text, [regex]::Escape($Query), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            for ($matchIndex = $recordMatches.Count - 1; $matchIndex -ge 0; $matchIndex--) {
                $textMatch = $recordMatches[$matchIndex]
                [void]$matches.Add([pscustomobject]@{ Record=$record; Start=[int]$textMatch.Index; Length=[int]$textMatch.Length })
            }
        }
        $script:CodexConversationSearchQuery = $Query
        $script:CodexConversationSearchMatches = @($matches)
        $script:CodexConversationSearchIndex = -1
        $script:CodexConversationSearchSignature = $signature
    }
    $matches = @($script:CodexConversationSearchMatches)
    if ($matches.Count -eq 0) { Clear-CodexConversationSearchSelection; Set-CodexConversationStatus ('未找到：' + $Query) 'Error'; return $false }
    Clear-CodexConversationSearchSelection
    $script:CodexConversationSearchIndex = ([int]$script:CodexConversationSearchIndex + 1) % $matches.Count
    $textMatch = $matches[$script:CodexConversationSearchIndex]
    if ($null -eq $textMatch.Record -or $null -eq $textMatch.Record.TextBox -or $textMatch.Record.TextBox.IsDisposed) { Reset-CodexConversationSearchState; Set-CodexConversationStatus '会话内容已变化，请再次查找' 'Busy'; return $false }
    $textMatch.Record.TextBox.SelectionStart = [Math]::Min([int]$textMatch.Start, $textMatch.Record.TextBox.TextLength)
    $textMatch.Record.TextBox.SelectionLength = [Math]::Min([int]$textMatch.Length, [Math]::Max(0, $textMatch.Record.TextBox.TextLength - $textMatch.Record.TextBox.SelectionStart))
    $script:CodexConversationSearchSelectedRecord = $textMatch.Record
    [void](Scroll-CodexConversationRecordIntoView $textMatch.Record -PreserveFocus -CharacterIndex ([int]$textMatch.Start))
    if ($null -ne $script:CodexConversationSearchBox -and -not $script:CodexConversationSearchBox.IsDisposed) {
        [void]$script:CodexConversationSearchBox.Focus(); $script:CodexConversationSearchBox.SelectionStart = $script:CodexConversationSearchBox.TextLength; $script:CodexConversationSearchBox.SelectionLength = 0
    }
    $displayQuery = if ($Query.Length -gt 18) { $Query.Substring(0,18) + '…' } else { $Query }
    Set-CodexConversationStatus ('查找 ' + ($script:CodexConversationSearchIndex + 1) + '/' + $matches.Count + ' · ' + $displayQuery)
    return $true
}

function Go-To-PreviousCodexUserMessage {
    if($null-eq$script:CodexConversationOutput-or$script:CodexConversationUserMessagePositions.Count-eq0){return $false}
    $count=$script:CodexConversationUserMessagePositions.Count
    if($script:CodexConversationUserNavigationIndex-gt$count){$script:CodexConversationUserNavigationIndex=$count}
    if($script:CodexConversationUserNavigationIndex-gt0){$script:CodexConversationUserNavigationIndex--}
    $record=Get-UiIndexedItemSafe $script:CodexConversationUserMessagePositions $script:CodexConversationUserNavigationIndex
    if($null-eq$record-or$record.Row.IsDisposed){return $false}
    return (Scroll-CodexConversationRecordIntoView $record)
}

function Get-CodexConversationWorkingDirectory {
    if ($script:CodexConversationMode -eq 'Project') {
        $project = Get-ProjectById ([string]$script:CodexConversationProjectId)
        if ($null -eq $project) { $project = $script:CurrentProject }
        if ($null -eq $project) { return '' }
        return (Resolve-ConfiguredPath ([string](Get-UiConfigValue $project 'DefaultWorkingDirectory' '')))
    }
    return (Resolve-ConfiguredPath ([string]$script:WorkflowAiDirectory))
}

function Test-CodexConversationTextFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.txt','.md','.markdown','.ps1','.psm1','.psd1','.py','.pyw','.js','.mjs','.cjs','.ts','.tsx','.jsx','.json','.jsonl','.xml','.xaml','.yaml','.yml','.ini','.cfg','.conf','.config','.log','.csv','.tsv','.sql','.cs','.vb','.cpp','.cc','.c','.h','.hpp','.java','.go','.rs','.php','.rb','.html','.htm','.css','.scss','.less','.vue','.svelte','.sh','.bash','.bat','.cmd','.toml','.properties','.env','.gitignore','.gitattributes','.editorconfig')) { return $true }
    $name = [IO.Path]::GetFileName($Path).ToLowerInvariant()
    return $name -in @('readme','license','copying','dockerfile','makefile','procfile','.env','.gitignore','.gitattributes','.editorconfig')
}

function Get-NotepadPlusPlusPath {
    param([switch]$AllowConfiguredFallback)
    $configured = Resolve-ConfiguredPath ([string](Get-UiConfigValue $script:GlobalSettings 'DocumentEditorPath' ''))
    if ([IO.File]::Exists($configured) -and [IO.Path]::GetFileName($configured) -ieq 'notepad++.exe') { return $configured }
    try {
        $command = Get-Command 'notepad++.exe' -ErrorAction Stop | Select-Object -First 1
        $commandPath = [string](Get-UiConfigValue $command 'Source' '')
        if ([string]::IsNullOrWhiteSpace($commandPath)) { $commandPath = [string](Get-UiConfigValue $command 'Path' '') }
        if ([IO.File]::Exists($commandPath)) { return $commandPath }
    } catch { }
    foreach ($candidate in @('C:\Program Files\Notepad++\notepad++.exe','C:\Program Files (x86)\Notepad++\notepad++.exe')) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    if ($AllowConfiguredFallback -and [IO.File]::Exists($configured)) { return $configured }
    return ''
}

function Get-CodexConversationFileLaunchSpec {
    param([string]$Path, [switch]$AllowEditorPrompt)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '文件或目录路径为空。' }
    $resolved = [Environment]::ExpandEnvironmentVariables($Path)
    try { $resolved = [IO.Path]::GetFullPath($resolved) } catch { }
    if ([IO.Directory]::Exists($resolved)) {
        return [pscustomobject]@{ Kind='Directory'; FilePath='explorer.exe'; Arguments=@($resolved); Target=$resolved }
    }
    if (-not [IO.File]::Exists($resolved)) { throw ('文件不存在：' + $resolved) }
    if (Test-CodexConversationTextFile $resolved) {
        $editor = Get-NotepadPlusPlusPath -AllowConfiguredFallback
        if ([string]::IsNullOrWhiteSpace($editor) -and $AllowEditorPrompt) { $editor = Get-DocumentEditorPath }
        if ([string]::IsNullOrWhiteSpace($editor)) { $editor = Join-Path $env:WINDIR 'System32\notepad.exe' }
        return [pscustomobject]@{ Kind='TextFile'; FilePath=$editor; Arguments=@($resolved); Target=$resolved }
    }
    return [pscustomobject]@{ Kind='DefaultFile'; FilePath=$resolved; Arguments=@(); Target=$resolved }
}

function Start-CodexConversationLaunch {
    param($Launch)
    if ($null -eq $Launch) { throw '打开参数为空。' }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=[string]$Launch.FilePath
    $arguments=@($Launch.Arguments)
    if($arguments.Count -gt 0){$info.Arguments=(($arguments|ForEach-Object{ConvertTo-NativeArgument ([string]$_)})-join ' ')}
    $target=[string](Get-UiConfigValue $Launch 'Target' '')
    $workingDirectory=''
    if([IO.File]::Exists($target)){$workingDirectory=[IO.Path]::GetDirectoryName($target)}elseif([IO.Directory]::Exists($target)){$workingDirectory=$target}
    if(-not[string]::IsNullOrWhiteSpace($workingDirectory)-and[IO.Directory]::Exists($workingDirectory)){$info.WorkingDirectory=$workingDirectory}
    $info.UseShellExecute=$true
    $process=[Diagnostics.Process]::Start($info)
    if($null-ne$process){$process.Dispose()}
}

function Open-CodexConversationFileTreeItem {
    param([string]$Path, [switch]$ReturnLaunchSpec)
    try {
        $launch = Get-CodexConversationFileLaunchSpec $Path -AllowEditorPrompt:(-not $ReturnLaunchSpec)
        if ($ReturnLaunchSpec) { return $launch }
        Start-CodexConversationLaunch $launch
        return $true
    } catch {
        Write-WorkflowLog ('打开文件树项目失败：' + $_.Exception.Message) 'ERROR'
        if (-not $ReturnLaunchSpec) { Show-Message ('无法打开：' + $_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning) }
        return $false
    }
}

function Open-CodexConversationFileTreeDirectory {
    param([string]$Path)
    try {
        $directory = Get-CodexConversationFileTreeWorkingDirectory $Path
        Start-CodexConversationLaunch ([pscustomobject]@{FilePath='explorer.exe';Arguments=@($directory);Target=$directory})
        return $true
    } catch {
        Write-WorkflowLog ('打开文件目录失败：' + $_.Exception.Message) 'ERROR'
        Show-Message ('无法打开目录：' + $_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }
}

function Resolve-CodexConversationFileTreePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '文件树路径为空。' }
    $resolved = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    try { $resolved = [IO.Path]::GetFullPath($resolved) } catch { }
    if (-not [IO.File]::Exists($resolved) -and -not [IO.Directory]::Exists($resolved)) { throw ('文件或目录不存在：' + $resolved) }
    return $resolved
}

function Get-CodexConversationFileTreeSelectedNode {
    $tree = $script:CodexConversationFileTree
    if ($null -eq $tree -or $tree.IsDisposed) { return $null }
    $node = $tree.SelectedNode
    if ($null -eq $node -or $null -eq $node.Tag -or [string]$node.Tag.Kind -notin @('File','Directory')) { return $null }
    return $node
}

function Get-CodexConversationFileTreeClipboardPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        if (-not [Windows.Forms.Clipboard]::ContainsFileDropList()) { return @() }
        $dropList = [Windows.Forms.Clipboard]::GetFileDropList()
        foreach ($item in $dropList) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) { [void]$paths.Add([string]$item) }
        }
    } catch { return @() }
    return @($paths)
}

function Get-CodexConversationFileTreePasteDirectory {
    param([Windows.Forms.TreeNode]$Node = $null)
    if ($null -ne $Node -and $null -ne $Node.Tag -and [string]$Node.Tag.Kind -in @('File','Directory')) {
        return Get-CodexConversationFileTreeWorkingDirectory ([string]$Node.Tag.Path)
    }
    return Resolve-CodexConversationFileTreePath (Get-CodexConversationWorkingDirectory)
}

function Get-CodexConversationFileTreePasteName {
    param([string]$SourcePath)
    $resolved = Resolve-CodexConversationFileTreePath $SourcePath
    if ([IO.Directory]::Exists($resolved)) { return ([IO.DirectoryInfo]$resolved).Name }
    return [IO.Path]::GetFileName($resolved)
}

function Get-CodexConversationFileTreePasteDestination {
    param([string]$DirectoryPath, [string]$SourcePath)
    $directory = Resolve-CodexConversationFileTreePath $DirectoryPath
    if (-not [IO.Directory]::Exists($directory)) { throw ('粘贴目标目录不存在：' + $directory) }
    $source = Resolve-CodexConversationFileTreePath $SourcePath
    $sourceKey = $source.TrimEnd('\','/').ToLowerInvariant()
    $directoryKey = $directory.TrimEnd('\','/').ToLowerInvariant()
    if ($directoryKey -eq $sourceKey -or $directoryKey.StartsWith($sourceKey + '\')) { throw '不能将目录粘贴到自身或其子目录中。' }
    $name = Get-CodexConversationFileTreePasteName $source
    $destination = Join-Path $directory $name
    if (-not [IO.File]::Exists($destination) -and -not [IO.Directory]::Exists($destination)) { return $destination }
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    $extension = [IO.Path]::GetExtension($name)
    $index = 1
    do {
        $suffix = if ($index -eq 1) { ' - 副本' } else { ' - 副本 (' + [string]$index + ')' }
        $candidate = Join-Path $directory ($base + $suffix + $extension)
        $index++
    } while ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate))
    return $candidate
}

function Copy-CodexConversationFileTreeItem {
    try {
        $node = Get-CodexConversationFileTreeSelectedNode
        if ($null -eq $node) { throw '请先选择要复制的文件或目录。' }
        $path = Resolve-CodexConversationFileTreePath ([string]$node.Tag.Path)
        $dropList = New-Object System.Collections.Specialized.StringCollection
        [void]$dropList.Add($path)
        [Windows.Forms.Clipboard]::SetFileDropList($dropList)
        if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '已复制文件树项目：' + $path }
        return $true
    } catch {
        Write-WorkflowLog ('复制文件树项目失败：' + $_.Exception.Message) 'ERROR'
        Show-Message ('无法复制：' + $_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }
}

function Paste-CodexConversationFileTreeItem {
    try {
        $sources = @(Get-CodexConversationFileTreeClipboardPaths)
        if ($sources.Count -eq 0) { throw '系统剪贴板中没有文件或目录。' }
        $node = Get-CodexConversationFileTreeSelectedNode
        $targetDirectory = Get-CodexConversationFileTreePasteDirectory $node
        $pasted = New-Object System.Collections.Generic.List[string]
        foreach ($source in $sources) {
            $resolvedSource = Resolve-CodexConversationFileTreePath $source
            $destination = Get-CodexConversationFileTreePasteDestination $targetDirectory $resolvedSource
            if ([IO.Directory]::Exists($resolvedSource)) { Copy-Item -LiteralPath $resolvedSource -Destination $destination -Recurse -Force }
            else { Copy-Item -LiteralPath $resolvedSource -Destination $destination -Force }
            [void]$pasted.Add($destination)
        }
        if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '已粘贴 ' + [string]$pasted.Count + ' 个文件树项目' }
        Refresh-CodexConversationFileTree
        return $true
    } catch {
        Write-WorkflowLog ('粘贴文件树项目失败：' + $_.Exception.Message) 'ERROR'
        Show-Message ('无法粘贴：' + $_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }
}

function Remove-CodexConversationFileTreeItem {
    try {
        $node = Get-CodexConversationFileTreeSelectedNode
        if ($null -eq $node) { throw '请先选择要删除的文件或目录。' }
        if ($node.Tag.IsRoot) { throw '不能删除当前工作目录。' }
        $path = Resolve-CodexConversationFileTreePath ([string]$node.Tag.Path)
        $answer = [Windows.Forms.MessageBox]::Show(('确定将“' + $path + '”移入回收站吗？'), '删除文件树项目', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return $false }
        if ([IO.Directory]::Exists($path)) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = '已删除文件树项目：' + $path }
        Refresh-CodexConversationFileTree
        return $true
    } catch {
        Write-WorkflowLog ('删除文件树项目失败：' + $_.Exception.Message) 'ERROR'
        Show-Message ('无法删除：' + $_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }
}

function Locate-CodexConversationFileTreeItem {
    param([string]$Path, [switch]$ReturnLaunchSpec)
    try {
        $resolved = Resolve-CodexConversationFileTreePath $Path
        $arguments = if ([IO.Directory]::Exists($resolved)) { @($resolved) } else { @('/select,' + [string][char]34 + $resolved + [string][char]34) }
        $arguments = @($arguments)
        $kind = if ([IO.Directory]::Exists($resolved)) { 'Directory' } else { 'File' }
        $launch = [pscustomobject]@{ Kind=$kind; FilePath='explorer.exe'; Arguments=$arguments; Target=$resolved }
        if ($ReturnLaunchSpec) { return $launch }
        Start-Process -FilePath $launch.FilePath -ArgumentList @($launch.Arguments) | Out-Null
        return $true
    } catch {
        Write-WorkflowLog ('定位文件树项目失败：' + $_.Exception.Message) 'ERROR'
        if (-not $ReturnLaunchSpec) { Show-Message ('无法定位：' + $_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning) }
        return $false
    }
}

function Get-CodexConversationFileTreeWorkingDirectory {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){throw '文件树路径为空。'}
    $resolved=[Environment]::ExpandEnvironmentVariables($Path)
    try{$resolved=[IO.Path]::GetFullPath($resolved)}catch{}
    if([IO.Directory]::Exists($resolved)){return $resolved}
    if([IO.File]::Exists($resolved)){return [IO.Path]::GetDirectoryName($resolved)}
    throw ('文件或目录不存在：'+$resolved)
}

function Open-CodexConversationFileTreeInPwd {
    param([string]$Path)
    try{
        $directory=Get-CodexConversationFileTreeWorkingDirectory $Path
        Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/k',('cd /d '+$directory+'')) -WorkingDirectory $directory | Out-Null
        return $true
    }catch{
        Write-WorkflowLog ('在 pwd 中打开文件树项目失败：'+$_.Exception.Message) 'ERROR'
        Show-Message ('无法打开：'+$_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }
}

function Open-CodexConversationFileTreeInPowerShell {
    param([string]$Path)
    try{
        $directory=Get-CodexConversationFileTreeWorkingDirectory $Path
        $quote=[string][char]39
        $literal=$directory.Replace($quote,$quote+$quote)
        Start-Process -FilePath (Get-WorkerPowerShellPath) -ArgumentList @('-NoExit','-Command',('Set-Location -LiteralPath '+$quote+$literal+$quote)) -WorkingDirectory $directory | Out-Null
        return $true
    }catch{
        Write-WorkflowLog ('在 PowerShell 中打开文件树项目失败：'+$_.Exception.Message) 'ERROR'
        Show-Message ('无法打开：'+$_.Exception.Message) '文件树' ([Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }
}

function Insert-CodexConversationFileTreePath {
    param([string]$Path)
    $box = $script:CodexConversationInput
    if ($null -eq $box -or $box.IsDisposed -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $box.SelectedText = $Path
    $box.SelectionLength = 0
    [void]$box.Focus()
    return $true
}

function Get-CodexConversationFileTreeLimit {
    param([string]$Path)
    $name = ''
    try { $name = ([IO.DirectoryInfo]$Path).Name.ToLowerInvariant() } catch { }
    if ($name -in @('.git','node_modules','.venv','venv','packages','__pycache__','bin','obj','dist')) { return 100 }
    return 300
}

function New-CodexConversationFileTreeTag {
    param([string]$Path, [string]$Kind, [bool]$Loaded, [bool]$IsRoot = $false)
    return [pscustomobject]@{ Path=$Path; Kind=$Kind; Loaded=$Loaded; Loading=$false; RequestId=''; IsRoot=$IsRoot }
}

function Remove-CodexConversationFileTreeRequestId {
    param([AllowEmptyString()][string]$RequestId)
    if ([string]::IsNullOrWhiteSpace($RequestId) -or $null -eq $script:CodexConversationFileTreeRequestIds) { return }
    try { [void]$script:CodexConversationFileTreeRequestIds.Remove($RequestId) } catch { }
    if($null-ne$script:CodexConversationFileTreeRequestContexts){try{[void]$script:CodexConversationFileTreeRequestContexts.Remove($RequestId)}catch{}}
}

function Add-CodexConversationFileTreePlaceholder {
    param([Windows.Forms.TreeNode]$Node, [string]$Text = '加载中…')
    $placeholder = New-Object Windows.Forms.TreeNode $Text
    $placeholder.ForeColor = [Drawing.Color]::FromArgb(148,163,184)
    $placeholder.Tag = New-CodexConversationFileTreeTag '' 'Notice' $true
    [void]$Node.Nodes.Add($placeholder)
}

function Complete-CodexConversationFileTreeLoad {
    param([WorkflowFileTreeResult]$Result)
    if($null-eq$Result){return}
    try{
        $requestId=[string]$Result.RequestId
        $context=if($null-ne$script:CodexConversationFileTreeRequestContexts-and$script:CodexConversationFileTreeRequestContexts.ContainsKey($requestId)){$script:CodexConversationFileTreeRequestContexts[$requestId]}else{$null}
        Remove-CodexConversationFileTreeRequestId $requestId
        if($null-eq$context){return}
        $tree=$context.Tree;$directoryNode=$context.Node
        if($null-eq$tree-or$tree.IsDisposed-or$null-eq$directoryNode-or$directoryNode.TreeView-ne$tree-or$null-eq$directoryNode.Tag){return}
        $currentTag=$directoryNode.Tag
        if($null-eq$currentTag-or[string]$currentTag.RequestId-ne$requestId-or[string]$currentTag.Path-ne[string]$Result.DirectoryPath){return}
        $tree.BeginUpdate()
        try{
            $directoryNode.Nodes.Clear()
            foreach($entry in $Result.Entries){
                $child=New-Object Windows.Forms.TreeNode ([string]$entry.Name)
                $child.ToolTipText=[string]$entry.FullPath
                if([bool]$entry.IsDirectory){
                    $child.Tag=New-CodexConversationFileTreeTag ([string]$entry.FullPath) 'Directory' $false
                    $child.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
                    Add-CodexConversationFileTreePlaceholder $child '展开以加载'
                }else{
                    $child.Tag=New-CodexConversationFileTreeTag ([string]$entry.FullPath) 'File' $true
                    $child.ForeColor=[Drawing.Color]::FromArgb(51,65,85)
                }
                [void]$directoryNode.Nodes.Add($child)
            }
            if(-not[string]::IsNullOrWhiteSpace([string]$Result.Error)){
                $errorNode=New-Object Windows.Forms.TreeNode ('无法读取：'+[string]$Result.Error)
                $errorNode.ForeColor=[Drawing.Color]::FromArgb(185,28,28)
                $errorNode.Tag=New-CodexConversationFileTreeTag '' 'Notice' $true
                [void]$directoryNode.Nodes.Add($errorNode)
            }
            if([bool]$Result.IsTruncated){
                $notice=New-Object Windows.Forms.TreeNode ('… 内容较多，仅显示前 '+[string]$Result.Limit+' 项')
                $notice.ForeColor=[Drawing.Color]::FromArgb(100,116,139)
                $notice.Tag=New-CodexConversationFileTreeTag '' 'Notice' $true
                [void]$directoryNode.Nodes.Add($notice)
            }
            $currentTag.Loading=$false;$currentTag.Loaded=$true
            if([bool]$currentTag.IsRoot){$directoryNode.Expand()}
        }finally{if($null-ne$tree-and-not$tree.IsDisposed){$tree.EndUpdate()}}
    }catch{
        try{if(-not[string]::IsNullOrWhiteSpace([string]$requestId)){Remove-CodexConversationFileTreeRequestId $requestId}}catch{}
        try{Write-WorkflowLog ('目录树异步加载回调失败：'+$_.Exception.Message) 'WARN'}catch{}
    }
}

function Load-CodexConversationFileTreeNode {
    param([Windows.Forms.TreeNode]$DirectoryNode)
    $tree=$script:CodexConversationFileTree
    if($null-eq$tree-or$tree.IsDisposed-or$null-eq$DirectoryNode-or$null-eq$DirectoryNode.Tag){return}
    $tag=$DirectoryNode.Tag
    if([string]$tag.Kind-ne'Directory'-or[bool]$tag.Loaded-or[bool]$tag.Loading){return}
    $path=[string]$tag.Path
    if(-not[string]::IsNullOrWhiteSpace([string]$tag.RequestId)){
        try{[WorkflowFileTreeLoader]::Cancel([string]$tag.RequestId)}catch{}
        Remove-CodexConversationFileTreeRequestId ([string]$tag.RequestId)
    }
    if($null-eq$script:CodexConversationFileTreeRequestIds){$script:CodexConversationFileTreeRequestIds=@{}}
    if($null-eq$script:CodexConversationFileTreeRequestContexts){$script:CodexConversationFileTreeRequestContexts=@{}}
    if($null-eq$script:CodexConversationFileTreeCallback){$script:CodexConversationFileTreeCallback=[Action[WorkflowFileTreeResult]]{param($result);Complete-CodexConversationFileTreeLoad $result}}
    $requestId=[guid]::NewGuid().ToString('N')
    $tag.Loading=$true;$tag.RequestId=$requestId
    $script:CodexConversationFileTreeRequestIds[$requestId]=$true
    $script:CodexConversationFileTreeRequestContexts[$requestId]=[pscustomobject]@{Tree=$tree;Node=$DirectoryNode}
    $DirectoryNode.Nodes.Clear();Add-CodexConversationFileTreePlaceholder $DirectoryNode
    [WorkflowFileTreeLoader]::Queue($tree,$path,(Get-CodexConversationFileTreeLimit $path),$requestId,$script:CodexConversationFileTreeCallback)
}

function Cancel-CodexConversationFileTreeRequests {
    if ($null -eq $script:CodexConversationFileTreeRequestIds) { return }
    foreach ($requestId in @($script:CodexConversationFileTreeRequestIds.Keys)) {
        try { [WorkflowFileTreeLoader]::Cancel([string]$requestId) } catch { }
    }
    try { $script:CodexConversationFileTreeRequestIds.Clear() } catch { $script:CodexConversationFileTreeRequestIds = @{} }
    if($null-ne$script:CodexConversationFileTreeRequestContexts){try{$script:CodexConversationFileTreeRequestContexts.Clear()}catch{$script:CodexConversationFileTreeRequestContexts=@{}}}
}

function Refresh-CodexConversationFileTree {
    $tree = $script:CodexConversationFileTree
    if ($null -eq $tree -or $tree.IsDisposed) { return }
    Cancel-CodexConversationFileTreeRequests
    $directory = Get-CodexConversationWorkingDirectory
    $script:CodexConversationFileTreeDirectory = $directory
    if ($null -ne $script:CodexConversationFileTreePathLabel) {
        $script:CodexConversationFileTreePathLabel.Text = if ([string]::IsNullOrWhiteSpace($directory)) { '未配置工作目录' } else { $directory }
    }
    if ($null -ne $script:CodexConversationFileTreeToolTip -and $null -ne $script:CodexConversationFileTreePathLabel) { $script:CodexConversationFileTreeToolTip.SetToolTip($script:CodexConversationFileTreePathLabel,$directory) }
    $tree.BeginUpdate()
    try {
        $tree.Nodes.Clear()
        if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Directory]::Exists($directory)) {
            $missing = New-Object Windows.Forms.TreeNode '当前工作目录不存在'
            $missing.ForeColor = [Drawing.Color]::FromArgb(185,28,28)
            $missing.Tag = New-CodexConversationFileTreeTag '' 'Notice' $true
            [void]$tree.Nodes.Add($missing)
            return
        }
        $rootName = ''
        try { $rootName = ([IO.DirectoryInfo]$directory).Name } catch { }
        if ([string]::IsNullOrWhiteSpace($rootName)) { $rootName = $directory }
        $root = New-Object Windows.Forms.TreeNode $rootName
        $root.ToolTipText = $directory
        $root.ForeColor = [Drawing.Color]::FromArgb(15,23,42)
        if($null-eq$script:CodexConversationFileTreeRootFont){$script:CodexConversationFileTreeRootFont=New-UiFont 9.5 ([Drawing.FontStyle]::Bold)}
        $root.NodeFont = $script:CodexConversationFileTreeRootFont
        $root.Tag = New-CodexConversationFileTreeTag $directory 'Directory' $false $true
        Add-CodexConversationFileTreePlaceholder $root
        [void]$tree.Nodes.Add($root)
        $root.Expand()
    } finally {
        $tree.EndUpdate()
    }
    Load-CodexConversationFileTreeNode $root
}

function Update-CodexConversationFileTreeLayout {
    $split = $script:CodexConversationSplit
    if ($null -eq $split -or $split.IsDisposed) { return }
    $width = [Math]::Max(1,$split.ClientSize.Width)
    $show = $script:CodexConversationFileTreeUserVisible -and $width -ge 860
    try {
        $split.Panel2Collapsed = -not $show
        if ($show) {
            $panel1Minimum = 420
            $panel2Minimum = 220
            $panelWidth = [Math]::Max(250,[Math]::Min(330,[int]($width * 0.27)))
            $distance = [Math]::Max($panel1Minimum,[Math]::Min($width-$panel2Minimum-$split.SplitterWidth,$width-$panelWidth-$split.SplitterWidth))
            if ($distance -gt 0) { $split.SplitterDistance = $distance }
        }
    } catch { }
    if ($null -ne $script:CodexConversationFileTreeToggleButton) { $script:CodexConversationFileTreeToggleButton.Text = if ($show) { '收起文件' } else { '文件树' } }
}

function Resolve-CodexConversationLinkTarget {
    param([string]$Target)
    $value=[Uri]::UnescapeDataString($Target.Trim().Trim('<','>'))
    $uri=$null;if([Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri)-and$uri.Scheme-in@('http','https')){return [pscustomobject]@{Kind='Url';Target=$uri.AbsoluteUri;Line=0}}
    if($value-match'^[/\\](?<drive>[A-Za-z]:[/\\].*)$'-and$value-notmatch'^[/\\]{2}'){$value=[string]$matches['drive']}
    $line=0
    # Codex also emits local file links with a fragment such as
    # D:/repo/file.cs#L203 or D:/repo/file.cs#L203-L220. Strip the fragment
    # before checking the file, otherwise the path is treated as nonexistent.
    if($value-match'^(?<path>.+)#L(?<line>\d+)(?:-L?\d+)?$'){
        $value=[string]$matches['path'];$line=[int]$matches['line']
    }elseif($value-match'^(?<path>.+)#line=(?<line>\d+)(?:-\d+)?$'){
        $value=[string]$matches['path'];$line=[int]$matches['line']
    }
    if($value-match'^(?<path>.+):(?<line>\d+)(?::\d+)?$'){
        $candidate=[string]$matches['path']
        $candidateLine=[int]$matches['line']
        $isWindowsDrivePath=$candidate-match'^[A-Za-z]:[/\\]'
        $isUncPath=$candidate-match'^[/\\]{2}'
        if($isWindowsDrivePath-or$isUncPath-or[IO.Path]::IsPathRooted($candidate)){$value=$candidate;$line=$candidateLine}
    }
    $value=[Environment]::ExpandEnvironmentVariables($value)
    if(-not[IO.Path]::IsPathRooted($value)){$base='';try{$base=Get-CodexConversationWorkingDirectory}catch{};if([string]::IsNullOrWhiteSpace($base)){$base=$script:WorkflowAiDirectory};$value=Join-Path $base $value}
    try{$value=[IO.Path]::GetFullPath($value)}catch{}
    if([IO.Directory]::Exists($value)){return [pscustomobject]@{Kind='Directory';Target=$value;Line=$line}}
    $extension=[IO.Path]::GetExtension($value).ToLowerInvariant()
    $kind=if($extension-eq'.exe'){'Executable'}elseif($extension-in@('.py','.ps1','.psm1','.psd1','.cs','.vb','.js','.jsx','.ts','.tsx','.json','.md','.txt','.log','.xml','.xaml','.yaml','.yml','.ini','.cfg','.conf','.html','.htm','.css','.scss','.sql','.bat','.cmd','.sh','.java','.c','.cc','.cpp','.h','.hpp','.go','.rs','.php','.rb','.toml','.csv')){'TextDocument'}else{'DefaultFile'}
    return [pscustomobject]@{Kind=$kind;Target=$value;Line=$line}
}

function Get-DocumentEditorPath {
    $configured=Resolve-ConfiguredPath ([string](Get-UiConfigValue $script:GlobalSettings 'DocumentEditorPath' ''))
    if([IO.File]::Exists($configured)){return $configured}
    $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Title='首次打开代码/文档：选择 Notepad++、记事本或其它编辑器';$dialog.Filter='编辑器程序 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    foreach($candidate in @('C:\Program Files\Notepad++\notepad++.exe','C:\Program Files (x86)\Notepad++\notepad++.exe')){if(Test-Path -LiteralPath $candidate){$dialog.FileName=$candidate;break}}
    if($dialog.ShowDialog($script:MainForm)-eq[Windows.Forms.DialogResult]::OK){$configured=$dialog.FileName}else{$configured=Join-Path $env:WINDIR 'System32\notepad.exe'}
    $dialog.Dispose();$script:GlobalSettings.DocumentEditorPath=$configured;Save-GlobalSettings;return $configured
}

function Invoke-CodexConversationLink {
    param([string]$Target)
    try{
        $link=Resolve-CodexConversationLinkTarget $Target
        switch($link.Kind){
            'Url'{Start-Process -FilePath $link.Target|Out-Null}
            'Directory'{Start-Process -FilePath 'explorer.exe' -ArgumentList @($link.Target)|Out-Null}
            'Executable'{if(-not[IO.File]::Exists($link.Target)){throw('文件不存在：'+$link.Target)};Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"'+$link.Target+'"')|Out-Null}
            'TextDocument'{if(-not[IO.File]::Exists($link.Target)){throw('文件不存在：'+$link.Target)};$editor=Get-DocumentEditorPath;$arguments=if([IO.Path]::GetFileName($editor)-like'notepad++*' -and [int]$link.Line-gt0){@('-n'+[string]$link.Line,$link.Target)}else{@($link.Target)};Start-Process -FilePath $editor -ArgumentList $arguments|Out-Null}
            default{if(-not[IO.File]::Exists($link.Target)){throw('文件不存在：'+$link.Target)};Start-Process -FilePath $link.Target|Out-Null}
        }
        return $true
    }catch{Write-WorkflowLog ('打开会话链接失败：'+$_.Exception.Message) 'ERROR';Show-Message ('无法打开链接：'+$_.Exception.Message) '会话链接' ([Windows.Forms.MessageBoxIcon]::Warning);return $false}
}

function Open-CodexConversationLinkAtPoint {
    param([Windows.Forms.RichTextBox]$Box,[Drawing.Point]$Point)
    $link=Get-CodexConversationLinkAtPoint $Box $Point
    if($null-eq$link){return $false};return (Invoke-CodexConversationLink ([string]$link.Target))
}

function Get-CodexConversationLinkAtPoint {
    param([Windows.Forms.RichTextBox]$Box,[Drawing.Point]$Point)
    if($null-eq$Box-or$Box.IsDisposed){return $null}
    $index=$Box.GetCharIndexFromPosition($Point)
    $links=if($null-ne$Box.Tag-and$null-ne$Box.Tag.PSObject.Properties['Links']){@($Box.Tag.Links)}else{@()}
    foreach($candidateIndex in @($index,($index-1),($index+1))){
        if($candidateIndex-lt0-or$candidateIndex-ge$Box.TextLength){continue}
        foreach($link in @($links)){
            if($candidateIndex-ge[int]$link.Start-and$candidateIndex-lt([int]$link.Start+[int]$link.Length)){return $link}
        }
    }
    return $null
}

function Open-CodexConversationLinkLocation {
    param([string]$Target,[switch]$ReturnLaunchSpec)
    try {
        Write-WorkflowLog ('Conversation link location requested; rawTarget='+[string]$Target) 'DEBUG'
        $link=Resolve-CodexConversationLinkTarget $Target
        if($null-eq$link-or[string]$link.Kind-in@('Url','Directory')){throw 'Only local file links support location.'}
        $path=[Environment]::ExpandEnvironmentVariables([string]$link.Target)
        try{$path=[IO.Path]::GetFullPath($path)}catch{}
        if(-not[IO.File]::Exists($path)){throw ('Resolved file does not exist: '+$path)}
        $explorer=Join-Path $env:WINDIR 'explorer.exe'
        $argument='/select,'+[string][char]34+$path+[string][char]34
        $launch=[pscustomobject]@{Kind='File';FilePath='explorer.exe';Arguments=@($argument);Target=$path}
        if($ReturnLaunchSpec){return $launch}
        # Explorer's /select parser is sensitive to PowerShell argument-array
        # expansion. Pass one complete argument string so Chinese paths and
        # paths containing spaces are handled consistently.
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=$explorer
        $startInfo.Arguments=$argument
        $startInfo.WorkingDirectory=[IO.Path]::GetDirectoryName($path)
        $startInfo.UseShellExecute=$true
        Write-WorkflowLog ('Conversation link location launching Explorer; resolvedPath='+$path+'; argument='+$argument) 'DEBUG'
        $process=[Diagnostics.Process]::Start($startInfo)
        if($null-eq$process){Start-Process -FilePath $explorer -ArgumentList $argument -WorkingDirectory $startInfo.WorkingDirectory|Out-Null}
        return $true
    }catch{
        Write-WorkflowLog ('Conversation link location failed; rawTarget='+[string]$Target+'; error='+$_.Exception.Message) 'ERROR'
        if(-not$ReturnLaunchSpec){Show-Message ('Unable to open file location: '+$_.Exception.Message) 'Conversation link' ([Windows.Forms.MessageBoxIcon]::Warning)}
        return $false
    }
}

function Ensure-CodexConversationLinkContextMenu {
    if($null -ne $script:CodexConversationLinkContextMenu -and -not $script:CodexConversationLinkContextMenu.IsDisposed){ return $script:CodexConversationLinkContextMenu }
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $menu.ShowImageMargin=$false
    $openLocation=New-Object Windows.Forms.ToolStripMenuItem '打开位置'
    $openLocation.ToolTipText='在资源管理器中打开所在目录并选中文件'
    [void]$menu.Items.Add($openLocation)
    $menu.Tag=$null
    $menu.Add_Opening({
        param($sender,$e)
        Write-WorkflowLog 'Conversation link context menu opening.' 'DEBUG'
        if($null -eq $sender.Tag -and $null -ne $script:CodexConversationLinkContext){ $sender.Tag=$script:CodexConversationLinkContext }
        if($null -eq $sender.Tag){
            Write-WorkflowLog 'Conversation link context menu opening cancelled because context is null.' 'ERROR'
            $e.Cancel=$true
            return
        }
        $context=$sender.Tag
        Write-WorkflowLog ('Conversation link context menu opened; rawTarget='+[string]$context.Target) 'DEBUG'
    })
    # Handle ItemClicked on the menu container. This is more reliable than
    # relying on a reused ToolStripMenuItem Click callback in a packaged host.
    $menu.Add_ItemClicked({
        param($sender,$e)
        if($null -eq $e -or $null -eq $e.ClickedItem -or $sender.Items.Count -eq 0 -or $e.ClickedItem -ne $sender.Items[0]){ return }
        Write-WorkflowLog 'Conversation link location menu clicked.' 'DEBUG'
        $context=$sender.Tag
        if($null -eq $context){ $context=$script:CodexConversationLinkContext }
        if($null -eq $context){
            Write-WorkflowLog 'Conversation link location menu clicked but context is null.' 'ERROR'
            return
        }
        Write-WorkflowLog ('Conversation link location menu target='+[string]$context.Target) 'DEBUG'
        try {
            [void](Open-CodexConversationLinkLocation ([string]$context.Target))
        } catch {
            Write-WorkflowLog ('Conversation link location menu action failed; rawTarget='+[string]$context.Target+'; error='+$_.Exception.Message) 'ERROR'
        } finally {
            $sender.Tag=$null
            $script:CodexConversationLinkContext=$null
        }
    })
    $menu.Add_Closed({
        param($sender,$e)
        Write-WorkflowLog 'Conversation link context menu closed.' 'DEBUG'
        $sender.Tag=$null
        $script:CodexConversationLinkContext=$null
    })
    $script:CodexConversationLinkContextMenu=$menu
    return $menu
}

function Add-CodexConversationMessage {
    param([string]$Role, [string]$Text, [string]$Time = '')
    if ($null -eq $script:CodexConversationOutput -or -not(Test-CodexConversationDisplayMessage $Role $Text)) { return }
    $isAssistantContinuation = $Role -eq 'assistant' -and $script:CodexConversationLastRole -eq 'assistant'
    $record=if($isAssistantContinuation-and$null-ne$script:CodexConversationCurrentBubble){$script:CodexConversationCurrentBubble}else{New-CodexConversationBubbleRecord $Role $Text}
    $script:CodexConversationRenderBox=$record.TextBox;$script:CodexConversationCurrentLinks=$record.Links
    $script:CodexConversationActiveBackColor=$record.TextBox.BackColor
    $record.TextBox.SelectionStart=$record.TextBox.TextLength;$record.TextBox.SelectionLength=0;$record.TextBox.SelectionAlignment=[Windows.Forms.HorizontalAlignment]::Left;$record.TextBox.SelectionIndent=0;$record.TextBox.SelectionRightIndent=0
    $label = if ($Role -eq 'user') { '我' } else { 'Codex' }
    if($Role-eq'user'){[void]$script:CodexConversationUserMessagePositions.Add($record);$script:CodexConversationUserNavigationIndex=$script:CodexConversationUserMessagePositions.Count}
    $timeLabel=Get-CodexConversationTimeLabel $Time
    if($isAssistantContinuation){
        $separator=if([string]::IsNullOrWhiteSpace($timeLabel)){'┈┈┈┈┈┈┈┈┈┈┈┈'}else{'┈┈┈┈  '+$timeLabel+'  ┈┈┈┈'}
        Add-CodexRichTextSegment ($separator+"`r`n") ([Drawing.Color]::FromArgb(148,163,184)) 7.4 ([Drawing.FontStyle]::Regular)
    }else{
        if(-not[string]::IsNullOrWhiteSpace($timeLabel)){$label+='  '+$timeLabel}
        $labelColor=if($Role-eq'user'){[Drawing.Color]::FromArgb(30,64,175)}else{[Drawing.Color]::FromArgb(13,116,144)}
        Add-CodexRichTextSegment ($label+"`r`n") $labelColor 9 ([Drawing.FontStyle]::Bold)
    }
    Add-CodexMarkdownText $Text
    $widthInfo=Get-CodexConversationDesiredWidth $Text $Role
    if([bool]$widthInfo.ExpandToMaximum){$record.ExpandToMaximum=$true}else{$record.DesiredWidth=[Math]::Max([int]$record.DesiredWidth,[int]$widthInfo.Width)}
    if(-not[bool]$script:CodexConversationBatchRendering){[void](Resize-CodexConversationBubbleRecord $record)}
    $transcriptLabel=if($isAssistantContinuation){$separator}else{$label}
    [void]$script:CodexConversationTranscriptParts.Add($transcriptLabel+"`r`n"+(Get-CodexConversationPlainText $Text))
    if(-not[bool]$script:CodexConversationBatchRendering){Commit-CodexConversationTranscript;Scroll-CodexConversationToBottom}
    $script:CodexConversationCurrentBubble=$record
    $script:CodexConversationLastRole=$Role
}

function Load-CodexConversationSession {
    param([string]$SessionId, [string]$DisplayName, [switch]$Refresh, [switch]$Incremental)
    $conversation = Get-CodexSessionConversation $SessionId 80 -Refresh:$Refresh
    $addedMessageCount=if($conversation.Found){@($conversation.AddedMessages).Count}else{0}
    $forceConversationCompaction = $Incremental -and $conversation.Found -and $null -ne $script:CodexConversationOutput -and (($script:CodexConversationBubbleRecords.Count + $addedMessageCount) -gt 140 -or (Get-CodexConversationRenderedTextLength) -gt $script:CodexConversationHistoryMaxCharacters)
    $requiresRender=if($conversation.Found){(-not$Incremental)-or[bool]$conversation.Reset-or$addedMessageCount-gt0-or$forceConversationCompaction}else{-not$Incremental}
    $previousBatchRendering=[bool]$script:CodexConversationBatchRendering
    $renderedChanges=$false
    if($requiresRender){$script:CodexConversationBatchRendering=$true}
    $freezeConversationRedraw=$requiresRender-and$null-ne$script:CodexConversationOutput-and-not$previousBatchRendering
    if($freezeConversationRedraw){[WorkflowNativeMethods]::SetControlRedraw($script:CodexConversationOutput,$false)}
    if($requiresRender-and$null-ne$script:CodexConversationOutput){$script:CodexConversationOutput.SuspendLayout()}
    try{
        if ($conversation.Found) {
            if (-not $Incremental -or $conversation.Reset -or $forceConversationCompaction) {
                Reset-CodexConversationOutput
                foreach ($message in @($conversation.Messages)) { Add-CodexConversationMessage ([string]$message.Role) ([string]$message.Text) ([string]$message.Time) }
                $renderedChanges=$true
            } else {
                foreach ($message in @($conversation.AddedMessages)) { Add-CodexConversationMessage ([string]$message.Role) ([string]$message.Text) ([string]$message.Time) }
                $renderedChanges=@($conversation.AddedMessages).Count-gt0
            }
            $directory = [string]$conversation.Session.working_directory
            $description = [string]$script:CodexConversationSessionDescription
            if($script:CodexConversationMode-eq'Project'){
                $project=Get-ProjectById $script:CodexConversationProjectId
                $session=Get-ProjectCodexSession $project $SessionId
                if($null-ne$session){$description=[string]$session.Description;$script:CodexConversationSessionModel=[string]$session.CodexModel}
            }
            if([string]::IsNullOrWhiteSpace($description)){$description='无描述'}
            $script:CodexConversationSessionDescription=$description
            $script:CodexConversationMeta.Text = "会话 $SessionId`r`n$directory"
            $script:CodexConversationMeta.Text = '会话描述：'+$description+'  ·  Session ID：'+$SessionId+'  ·  目录：'+$directory
            $processKey = Get-CodexConversationProcessKey $script:CodexConversationMode $script:CodexConversationProjectId $SessionId
            if (Test-CodexConversationProcessRunning $processKey) { Set-CodexConversationStatus '会话后台执行中 · 自动刷新已开启' 'Busy' }
            elseif (Test-CodexConversationProcessBusy $processKey) { Set-CodexConversationStatus 'Codex 已退出，正在同步回复...' 'Busy' }
            elseif ($Incremental -and $addedMessageCount -gt 0) { Set-CodexConversationStatus ('已追加 ' + $addedMessageCount + ' 条新消息') }
            else { Set-CodexConversationStatus ('已恢复历史会话 · ' + @($conversation.Messages).Count + ' 条消息') }
        } else {
            $script:CodexConversationMeta.Text = "会话 $SessionId"
            $script:CodexConversationMeta.Text = '会话描述：'+$script:CodexConversationSessionDescription+'  ·  Session ID：'+$SessionId
            Set-CodexConversationStatus '未找到本地会话记录，发送时仍会尝试 resume' 'Error'
            if (-not $Incremental) {
                Reset-CodexConversationOutput
                Add-CodexConversationMessage 'assistant' ('未能从本机会话记录加载“' + $DisplayName + '”。请检查会话 ID，或使用“终端打开”查看 Codex 的错误信息。')
                $renderedChanges=$true
            }
        }
    }finally{
        if($requiresRender){
            $script:CodexConversationBatchRendering=$previousBatchRendering
            if($null-ne$script:CodexConversationOutput){$script:CodexConversationOutput.ResumeLayout($true)}
            try{
                if($renderedChanges-and-not$previousBatchRendering){Complete-CodexConversationBatchRender -ScrollToBottom}
            }finally{
                if($freezeConversationRedraw){[WorkflowNativeMethods]::SetControlRedraw($script:CodexConversationOutput,$true)}
            }
        }
    }
}

function Refresh-CodexConversation {
    param([switch]$Automatic)
    if($Automatic){$script:CodexConversationAutomaticRefreshes++}
    if ($script:CodexConversationMode -eq 'WorkflowAi') {
        $sessionId = [string]$script:GlobalSettings.WorkflowAiSessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) { Show-WorkflowAiConversation; return }
        Load-CodexConversationSession $sessionId '使驾 AI' -Refresh:(-not $Automatic) -Incremental
        if(-not$Automatic){$script:WorkflowAiConversationHistory = Limit-CodexConversationHistoryText $script:CodexConversationOutput.Text $script:CodexConversationHistoryMaxEntryCharacters}
        return
    }
    if ($null -ne $script:CurrentProject) {
        $sessionId = [string]$script:CurrentProject.CodexSessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            Reset-CodexConversationOutput
            $script:CodexConversationMeta.Text='项目目录：' + [string]$script:CurrentProject.DefaultWorkingDirectory + "`r`n会话尚未创建"
            Set-CodexConversationStatus '发送第一条消息后自动创建并绑定会话' 'Busy'
            Add-CodexConversationMessage 'assistant' '当前项目尚未关联 Codex 会话。发送第一条消息后，将基于项目默认工作目录创建新会话并自动绑定。'
        } else {
            Load-CodexConversationSession $sessionId ([string]$script:CurrentProject.Name) -Refresh:(-not $Automatic) -Incremental
        }
        if(-not$Automatic){Set-CodexConversationHistoryCache ([string]$script:CurrentProject.Id) $script:CodexConversationOutput.Text}
    }
}

function Show-ProjectConversation {
    if($null -eq $script:CurrentProject){Show-Message '请先选择一个项目。' 'Codex 对话' ([Windows.Forms.MessageBoxIcon]::Information);return}
    $directory=Resolve-CodexWorkingDirectory ([string]$script:CurrentProject.DefaultWorkingDirectory)
    if([string]::IsNullOrWhiteSpace($directory)-or-not[IO.Directory]::Exists($directory)){Show-Message '项目默认工作目录不存在，无法打开 Codex 对话。' 'Codex 对话' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    if($script:CodexConversationMode -eq 'WorkflowAi'){$script:WorkflowAiConversationHistory=$script:CodexConversationOutput.Text}
    elseif(-not[string]::IsNullOrWhiteSpace($script:CodexConversationProjectId)){Set-CodexConversationHistoryCache $script:CodexConversationProjectId $script:CodexConversationOutput.Text}
    $script:WorkflowSettingsPanel.Visible=$false; $script:WorkflowLogPanel.Visible=$false; $script:Canvas.Visible=$false
    if($null-ne$script:RunningTasksPanel){$script:RunningTasksPanel.Visible=$false}
    Hide-EmbeddedCommonPromptsPanel
    if($null-ne$script:SessionManagerPanel){$script:SessionManagerPanel.Visible=$false}
    $script:CodexConversationPanel.Visible=$true; $script:CodexConversationPanel.BringToFront()
    $script:CodexConversationMode='Project'
    if($null-ne$script:CodexConversationTerminalButton){$script:CodexConversationTerminalButton.Visible=$true}
    $script:CodexConversationTitle.Text = 'Codex 会话  /  ' + [string]$script:CurrentProject.Name
    $script:CodexConversationProjectId = [string]$script:CurrentProject.Id
    Update-CodexConversationFileTreeLayout
    Refresh-CodexConversationFileTree
    $sessionId=[string]$script:CurrentProject.CodexSessionId
    if([string]::IsNullOrWhiteSpace($sessionId)){
        Reset-CodexConversationOutput
        $script:CodexConversationMeta.Text='项目目录：'+$directory+"`r`n会话尚未创建"
        Set-CodexConversationStatus '发送第一条消息后自动创建并绑定会话' 'Busy'
        Add-CodexConversationMessage 'assistant' '当前项目尚未关联 Codex 会话。发送第一条消息后，将基于项目默认工作目录创建新会话并自动绑定。'
    }else{Load-CodexConversationSession $sessionId ([string]$script:CurrentProject.Name)}
    Set-CodexConversationHistoryCache $script:CodexConversationProjectId $script:CodexConversationOutput.Text
    Update-CodexConversationControls
    $script:CodexConversationInput.Focus()
}

function Save-CurrentCodexConversationHistory {
    if($null-eq$script:CodexConversationOutput){return}
    if($script:CodexConversationMode-eq'WorkflowAi'){$script:WorkflowAiConversationHistory=Limit-CodexConversationHistoryText $script:CodexConversationOutput.Text $script:CodexConversationHistoryMaxEntryCharacters;return}
    if(-not[string]::IsNullOrWhiteSpace($script:CodexConversationProjectId)){
        $historyKey=Get-CodexConversationHistoryKey 'Project' $script:CodexConversationProjectId $script:CodexConversationSessionId
        Set-CodexConversationHistoryCache $historyKey $script:CodexConversationOutput.Text
    }
}

function Set-CodexConversationProjectSession {
    param($Project,[AllowEmptyString()][string]$SessionId='', [object]$SelectedSession=$null)
    $session=$SelectedSession
    if($null-eq$session){$session=Get-ProjectCodexSession $Project $SessionId}
    if($null-eq$session-and[string]::IsNullOrWhiteSpace($SessionId)){$session=Get-ProjectPrimaryCodexSession $Project}
    if($null-ne$session){
        $script:CodexConversationSessionId=[string]$session.SessionId
        $script:CodexConversationSessionDescription=[string]$session.Description
        $script:CodexConversationSessionModel=[string]$session.CodexModel
    }else{
        $script:CodexConversationSessionId=''
        $script:CodexConversationSessionDescription='无描述'
        $script:CodexConversationSessionModel=''
    }
    if([string]::IsNullOrWhiteSpace($script:CodexConversationSessionDescription)){$script:CodexConversationSessionDescription='无描述'}
}

function Refresh-CodexConversationSessionSelector {
    $selector=$script:CodexConversationSessionSelector
    if($null-eq$selector-or$selector.IsDisposed-or$script:CodexConversationSessionSelectorRefreshActive){return}
    $show=$script:CodexConversationMode-eq'Project'-and-not[string]::IsNullOrWhiteSpace($script:CodexConversationProjectId)
    $selector.Visible=$show
    if(-not$show){return}
    $project=Get-ProjectById $script:CodexConversationProjectId
    if($null-eq$project){return}
    $sessions=@(Get-ProjectCodexSessions $project)
    $script:CodexConversationSessionSelectorRefreshActive=$true
    $script:CodexConversationSessionSelectorBinding=$true
    try{
        $selector.BeginUpdate();$selector.Items.Clear()
        if($sessions.Count-eq0){
            [void]$selector.Items.Add([pscustomobject]@{DisplayText='未创建会话';SessionId='';Description='无描述';CodexModel=''})
        }else{
            for($index=0;$index-lt$sessions.Count;$index++){
                $session=$sessions[$index];$description=[string]$session.Description;if([string]::IsNullOrWhiteSpace($description)){$description='无描述'}
                $prefix=if($index-eq0){'主会话 · '}else{''}
                $pendingSuffix=if([string]::IsNullOrWhiteSpace([string]$session.SessionId)){' · 待首次发送创建'}else{''}
                [void]$selector.Items.Add([pscustomobject]@{DisplayText=$prefix+$description+$pendingSuffix;SessionId=[string]$session.SessionId;Description=$description;CodexModel=[string]$session.CodexModel})
            }
        }
        $selectedIndex=0
        for($index=0;$index-lt$selector.Items.Count;$index++){
            $item=$selector.Items[$index]
            $idMatches=[string]$item.SessionId-eq[string]$script:CodexConversationSessionId
            $pendingMatches=$idMatches-and[string]::IsNullOrWhiteSpace([string]$item.SessionId)-and[string]$item.Description-eq[string]$script:CodexConversationSessionDescription-and[string]$item.CodexModel-eq[string]$script:CodexConversationSessionModel
            if(($idMatches-and-not[string]::IsNullOrWhiteSpace([string]$item.SessionId)) -or $pendingMatches){$selectedIndex=$index;break}
        }
        if($selector.Items.Count-gt0){$selectedIndex=[Math]::Max(0,[Math]::Min($selectedIndex,$selector.Items.Count-1));$selector.SelectedIndex=$selectedIndex}
    }catch{
        try{$selector.SelectedIndex=-1}catch{}
    }finally{
        try{$selector.EndUpdate()}catch{}
        $script:CodexConversationSessionSelectorBinding=$false
        $script:CodexConversationSessionSelectorRefreshActive=$false
    }
}

function Update-CodexConversationProjectHeader {
    param($Project,[switch]$SkipSelectorRefresh)
    if($null-eq$Project){return}
    $script:CodexConversationTitle.Text='Codex 会话  /  '+[string]$Project.Name+'  /  '+$script:CodexConversationSessionDescription
    $directory=Resolve-CodexWorkingDirectory ([string]$Project.DefaultWorkingDirectory)
    if([string]::IsNullOrWhiteSpace($script:CodexConversationSessionId)){
        $script:CodexConversationMeta.Text='会话描述：'+$script:CodexConversationSessionDescription+'  ·  会话尚未创建  ·  目录：'+$directory
    }else{
        $script:CodexConversationMeta.Text='会话描述：'+$script:CodexConversationSessionDescription+'  ·  Session ID：'+$script:CodexConversationSessionId+'  ·  目录：'+$directory
    }
    if(-not$SkipSelectorRefresh){Refresh-CodexConversationSessionSelector}
    if($null-ne$script:CodexConversationHeaderLayoutHandler){& $script:CodexConversationHeaderLayoutHandler}
}

function Switch-CodexConversationProjectSession {
    param($Selection)
    if($script:CodexConversationSessionSelectorBinding-or$script:CodexConversationMode-ne'Project'-or$null-eq$Selection){return}
    $project=Get-ProjectById $script:CodexConversationProjectId;if($null-eq$project){return}
    $nextSessionId=[string](Get-UiConfigValue $Selection 'SessionId' '')
    $projectSessions=@(Get-ProjectCodexSessions $project)
    if($projectSessions.Count-eq0){if(-not[string]::IsNullOrWhiteSpace($nextSessionId)){return}}
    elseif(@($projectSessions|Where-Object{[string]$_.SessionId-eq$nextSessionId}).Count-eq0){return}
    $nextDescription=[string](Get-UiConfigValue $Selection 'Description' '无描述')
    $nextModel=[string](Get-UiConfigValue $Selection 'CodexModel' '')
    if($nextSessionId-eq[string]$script:CodexConversationSessionId-and$nextDescription-eq[string]$script:CodexConversationSessionDescription-and$nextModel-eq[string]$script:CodexConversationSessionModel){return}
    Save-CurrentCodexConversationHistory
    Set-CodexConversationProjectSession $project $nextSessionId -SelectedSession $Selection
    Update-CodexConversationProjectHeader $project -SkipSelectorRefresh
    Refresh-CodexConversationFileTree
    if([string]::IsNullOrWhiteSpace($script:CodexConversationSessionId)){
        Reset-CodexConversationOutput
        Add-CodexConversationMessage 'assistant' '当前项目尚未关联 Codex 会话。发送第一条消息后，将基于项目默认工作目录创建新会话并自动绑定，描述默认为“无描述”。'
        Set-CodexConversationStatus '发送第一条消息后自动创建并绑定会话' 'Busy'
    }else{
        Load-CodexConversationSession $script:CodexConversationSessionId ([string]$project.Name)
    }
    $historyKey=Get-CodexConversationHistoryKey 'Project' ([string]$project.Id) $script:CodexConversationSessionId
    Set-CodexConversationHistoryCache $historyKey $script:CodexConversationOutput.Text
    Update-CodexConversationControls
}

function Request-CodexConversationProjectSessionSwitch {
    param($Sender)
    if($null-eq$Sender-or$Sender.IsDisposed-or$script:CodexConversationSessionSelectorBinding-or$script:CodexConversationSessionSelectorRefreshActive){return}
    $script:CodexConversationSessionSwitchSender=$Sender
    if($null-eq$script:CodexConversationSessionSwitchCallback){$script:CodexConversationSessionSwitchCallback=[Action]{
        try{
            $switchSender=$script:CodexConversationSessionSwitchSender
            $script:CodexConversationSessionSwitchSender=$null
            if($null-eq$switchSender-or$switchSender.IsDisposed-or$script:CodexConversationSessionSelectorBinding){return}
            $selection=$switchSender.SelectedItem
            if($null-ne$selection){Switch-CodexConversationProjectSession $selection}
        }catch{}
    }}
    try{
        if($Sender.IsHandleCreated){[void]$Sender.BeginInvoke($script:CodexConversationSessionSwitchCallback)}else{& $script:CodexConversationSessionSwitchCallback}
    }catch{try{& $script:CodexConversationSessionSwitchCallback}catch{}}
}

function Refresh-CodexConversation {
    param([switch]$Automatic)
    if($Automatic){$script:CodexConversationAutomaticRefreshes++}
    if($script:CodexConversationMode-eq'WorkflowAi'){
        $sessionId=[string]$script:GlobalSettings.WorkflowAiSessionId
        if([string]::IsNullOrWhiteSpace($sessionId)){if(-not$Automatic){Show-WorkflowAiConversation};return}
        Load-CodexConversationSession $sessionId '使驾 AI' -Refresh:(-not$Automatic) -Incremental
        if(-not$Automatic){$script:WorkflowAiConversationHistory=Limit-CodexConversationHistoryText $script:CodexConversationOutput.Text $script:CodexConversationHistoryMaxEntryCharacters}
        return
    }
    $project=Get-ProjectById $script:CodexConversationProjectId
    if($null-eq$project){return}
    $sessionId=[string]$script:CodexConversationSessionId
    if([string]::IsNullOrWhiteSpace($sessionId)){
        if(-not$Automatic){
            Reset-CodexConversationOutput
            Update-CodexConversationProjectHeader $project
            Set-CodexConversationStatus '发送第一条消息后自动创建并绑定会话' 'Busy'
            Add-CodexConversationMessage 'assistant' '当前项目尚未关联 Codex 会话。发送第一条消息后，将基于项目默认工作目录创建新会话并自动绑定，描述默认为“无描述”。'
        }
    }else{Load-CodexConversationSession $sessionId ([string]$project.Name) -Refresh:(-not$Automatic) -Incremental}
    $historyKey=Get-CodexConversationHistoryKey 'Project' ([string]$project.Id) $sessionId
    if(-not$Automatic){Set-CodexConversationHistoryCache $historyKey $script:CodexConversationOutput.Text}
}

function Show-ProjectConversation {
    param([AllowEmptyString()][string]$SessionId='', [switch]$UseSelectedSession, [object]$SelectedSession=$null)
    if($null-eq$script:CurrentProject){Show-Message '请先选择一个项目。' 'Codex 对话' ([Windows.Forms.MessageBoxIcon]::Information);return}
    $directory=Resolve-CodexWorkingDirectory ([string]$script:CurrentProject.DefaultWorkingDirectory)
    if([string]::IsNullOrWhiteSpace($directory)-or-not[IO.Directory]::Exists($directory)){Show-Message '项目默认工作目录不存在，无法打开 Codex 对话。' 'Codex 对话' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    $requestedSession=$SelectedSession
    if($null-eq$requestedSession){
        if(-not[string]::IsNullOrWhiteSpace($SessionId)){$requestedSession=Get-ProjectCodexSession $script:CurrentProject $SessionId}
        elseif(-not$UseSelectedSession){$requestedSession=Get-ProjectPrimaryCodexSession $script:CurrentProject}
    }
    $requestedSessionId=if($null-ne$requestedSession){[string](Get-UiConfigValue $requestedSession 'SessionId' '')}else{[string]$SessionId}
    $requestedDescription=if($null-ne$requestedSession){[string](Get-UiConfigValue $requestedSession 'Description' '无描述')}else{'无描述'}
    if([string]::IsNullOrWhiteSpace($requestedDescription)){$requestedDescription='无描述'}
    $sameConversation=$script:CodexConversationMode-eq'Project'-and[string]$script:CodexConversationProjectId-eq[string]$script:CurrentProject.Id-and[string]$script:CodexConversationSessionId-eq$requestedSessionId-and[string]$script:CodexConversationSessionDescription-eq$requestedDescription
    if($sameConversation){
        $script:WorkflowSettingsPanel.Visible=$false;$script:WorkflowLogPanel.Visible=$false;$script:Canvas.Visible=$false
        if($null-ne$script:RunningTasksPanel){$script:RunningTasksPanel.Visible=$false};Hide-EmbeddedCommonPromptsPanel;if($null-ne$script:SessionManagerPanel){$script:SessionManagerPanel.Visible=$false}
        $script:CodexConversationPanel.Visible=$true;$script:CodexConversationPanel.BringToFront()
        if($null-ne$script:CodexConversationTerminalButton){$script:CodexConversationTerminalButton.Visible=$true}
        Update-CodexConversationProjectHeader $script:CurrentProject
        Update-CodexConversationFileTreeLayout;Update-CodexConversationControls;Refresh-CodexConversationVisibleSurface -ForceBubbleLayout;$script:CodexConversationInput.Focus()
        return
    }
    Save-CurrentCodexConversationHistory
    $script:WorkflowSettingsPanel.Visible=$false;$script:WorkflowLogPanel.Visible=$false;$script:Canvas.Visible=$false
    if($null-ne$script:RunningTasksPanel){$script:RunningTasksPanel.Visible=$false};Hide-EmbeddedCommonPromptsPanel;if($null-ne$script:SessionManagerPanel){$script:SessionManagerPanel.Visible=$false}
    $script:CodexConversationPanel.Visible=$true;$script:CodexConversationPanel.BringToFront();$script:CodexConversationMode='Project';$script:CodexConversationProjectId=[string]$script:CurrentProject.Id
    if(-not$UseSelectedSession-and[string]::IsNullOrWhiteSpace($SessionId)-and$script:CodexConversationMode-eq'Project'){$SessionId=[string](Get-UiConfigValue (Get-ProjectPrimaryCodexSession $script:CurrentProject) 'SessionId' '')}
    if($UseSelectedSession){Set-CodexConversationProjectSession $script:CurrentProject $SessionId -SelectedSession $SelectedSession}else{Set-CodexConversationProjectSession $script:CurrentProject $SessionId}
    if($null-ne$script:CodexConversationTerminalButton){$script:CodexConversationTerminalButton.Visible=$true}
    Update-CodexConversationProjectHeader $script:CurrentProject
    Update-CodexConversationFileTreeLayout;Refresh-CodexConversationFileTree
    if([string]::IsNullOrWhiteSpace($script:CodexConversationSessionId)){
        Reset-CodexConversationOutput
        Add-CodexConversationMessage 'assistant' '当前项目尚未关联 Codex 会话。发送第一条消息后，将基于项目默认工作目录创建新会话并自动绑定，描述默认为“无描述”。'
        Set-CodexConversationStatus '发送第一条消息后自动创建并绑定会话' 'Busy'
    }else{Load-CodexConversationSession $script:CodexConversationSessionId ([string]$script:CurrentProject.Name)}
    $historyKey=Get-CodexConversationHistoryKey 'Project' $script:CodexConversationProjectId $script:CodexConversationSessionId
    Set-CodexConversationHistoryCache $historyKey $script:CodexConversationOutput.Text
    Update-CodexConversationControls;Refresh-CodexConversationVisibleSurface -ForceBubbleLayout;$script:CodexConversationInput.Focus()
}

function Show-CurrentProjectConversationEntry {
    if($null-eq$script:CurrentProject){Show-ProjectConversation;return}
    $sessions=@(Get-ProjectCodexSessions $script:CurrentProject)
    if($sessions.Count-le1){if($sessions.Count-eq1){Show-ProjectConversation -SessionId ([string]$sessions[0].SessionId) -UseSelectedSession -SelectedSession $sessions[0]}else{Show-ProjectConversation};return}
    if($null-ne$script:ProjectConversationMenu){try{$script:ProjectConversationMenu.Dispose()}catch{}}
    $menu=New-Object Windows.Forms.ContextMenuStrip;$script:ProjectConversationMenu=$menu
    for($index=0;$index-lt$sessions.Count;$index++){
        $session=$sessions[$index];$description=[string]$session.Description;if([string]::IsNullOrWhiteSpace($description)){$description='无描述'}
        $caption=if($index-eq0){'主会话 · '+$description}else{$description}
        $item=$menu.Items.Add($caption);$item.Tag=$session
        $item.Add_Click({param($sender,$e);$selected=$sender.Tag;if($null-ne$selected){Show-ProjectConversation -SessionId ([string]$selected.SessionId) -UseSelectedSession -SelectedSession $selected}})
    }
    $menu.Show($script:ProjectChatButton,(New-Object Drawing.Point(0,$script:ProjectChatButton.Height)))
}

function Show-WorkflowAiConversation {
    $script:WorkflowSettingsPanel.Visible=$false; $script:WorkflowLogPanel.Visible=$false; $script:Canvas.Visible=$false
    if($null-ne$script:RunningTasksPanel){$script:RunningTasksPanel.Visible=$false}
    Hide-EmbeddedCommonPromptsPanel
    if($null-ne$script:SessionManagerPanel){$script:SessionManagerPanel.Visible=$false}
    $script:CodexConversationPanel.Visible=$true; $script:CodexConversationPanel.BringToFront()
    if($script:CodexConversationMode -eq 'Project' -and -not[string]::IsNullOrWhiteSpace($script:CodexConversationProjectId)){Set-CodexConversationHistoryCache $script:CodexConversationProjectId $script:CodexConversationOutput.Text}
    $script:CodexConversationMode='WorkflowAi'
    $script:CodexConversationProjectId='';$script:CodexConversationSessionId=[string]$script:GlobalSettings.WorkflowAiSessionId;$script:CodexConversationSessionDescription='使驾 AI';$script:CodexConversationSessionModel=''
    if($null-ne$script:CodexConversationSessionSelector){$script:CodexConversationSessionSelector.Visible=$false}
    $script:CodexConversationTitle.Text='使驾 AI  /  独立工作流助手'
    Update-CodexConversationFileTreeLayout
    Refresh-CodexConversationFileTree
    if($null-ne$script:CodexConversationTerminalButton){$script:CodexConversationTerminalButton.Visible=$false}
    $sessionId = [string]$script:GlobalSettings.WorkflowAiSessionId
    if([string]::IsNullOrWhiteSpace($sessionId)){
        Reset-CodexConversationOutput
        $script:CodexConversationMeta.Text='独立持久会话 · 尚未创建'
        Set-CodexConversationStatus '发送第一条消息后自动创建会话' 'Busy'
        Add-CodexConversationMessage 'assistant' '我是使驾 AI。可以让我整理 Codex 历史会话、创建项目，或维护项目中的工作流。'
    }else{
        Load-CodexConversationSession $sessionId '使驾 AI'
        $script:WorkflowAiConversationHistory=Limit-CodexConversationHistoryText $script:CodexConversationOutput.Text $script:CodexConversationHistoryMaxEntryCharacters
    }
    Update-CodexConversationControls
    Refresh-CodexConversationVisibleSurface -ForceBubbleLayout
    $script:CodexConversationInput.Focus()
}

function Open-CurrentProjectPath {
    if($null -eq $script:CurrentProject){Show-Message '“无项目”没有默认目录。' '打开路径' ([Windows.Forms.MessageBoxIcon]::Information);return}
    $path=Resolve-ConfiguredPath ([string]$script:CurrentProject.DefaultWorkingDirectory)
    if(-not [IO.Directory]::Exists($path)){Show-Message '项目路径不存在。' '打开路径' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    Start-Process -FilePath 'explorer.exe' -ArgumentList @($path) | Out-Null
}

function Get-VSCodeLaunchSpec {
    param([string]$WorkingDirectory, [string]$ConfiguredPath = '')
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not [IO.Directory]::Exists($WorkingDirectory)) { return $null }
    try {
        $codeCommand = Get-Command code -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $codeCommand -and -not [string]::IsNullOrWhiteSpace([string]$codeCommand.Source)) {
            return [pscustomobject]@{ FilePath=[string]$codeCommand.Source; Arguments=@('.'); WorkingDirectory=$WorkingDirectory; Source='code' }
        }
    } catch { }
    $resolvedPath = Resolve-ConfiguredPath $ConfiguredPath
    if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and [IO.File]::Exists($resolvedPath)) {
        return [pscustomobject]@{ FilePath=$resolvedPath; Arguments=@('.'); WorkingDirectory=$WorkingDirectory; Source='configured' }
    }
    return $null
}

function Open-CurrentProjectInVSCode {
    if($null -eq $script:CurrentProject){Show-Message '请先选择一个项目。' 'VS Code' ([Windows.Forms.MessageBoxIcon]::Information);return}
    $path=Resolve-ConfiguredPath ([string]$script:CurrentProject.DefaultWorkingDirectory)
    if(-not [IO.Directory]::Exists($path)){Show-Message '项目默认工作目录不存在。' 'VS Code' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    $launch = Get-VSCodeLaunchSpec $path ([string]$script:GlobalSettings.VSCodePath)
    if($null-eq$launch){Show-Message '未找到 code 命令，也未配置有效的 VS Code 路径。' 'VS Code' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    Start-Process -FilePath $launch.FilePath -ArgumentList $launch.Arguments -WorkingDirectory $launch.WorkingDirectory | Out-Null
}

function Open-CurrentProjectCodexTerminal {
    if($null -eq $script:CurrentProject){Show-Message '请先选择一个项目。' 'Codex 终端' ([Windows.Forms.MessageBoxIcon]::Information);return}
    $terminalSession=if($script:CodexConversationMode-eq'Project'-and[string]$script:CodexConversationProjectId-eq[string]$script:CurrentProject.Id){Get-ProjectCodexSession $script:CurrentProject $script:CodexConversationSessionId}else{Get-ProjectPrimaryCodexSession $script:CurrentProject}
    $sessionId=if($null-ne$terminalSession){[string]$terminalSession.SessionId}else{''}
    if([string]::IsNullOrWhiteSpace($sessionId)){Show-Message '当前项目尚未配置 Codex 会话 ID。' 'Codex 终端' ([Windows.Forms.MessageBoxIcon]::Information);return}
    $codex=Resolve-ConfiguredPath ([string]$script:GlobalSettings.CodexPath)
    $directory=Resolve-CodexWorkingDirectory ([string]$script:CurrentProject.DefaultWorkingDirectory)
    if(-not [IO.File]::Exists($codex)){Show-Message '全局 Codex 路径不存在。' 'Codex 终端' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    if(-not [IO.Directory]::Exists($directory)){Show-Message '项目默认工作目录不存在。' 'Codex 终端' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    $command=New-CodexInteractiveResumeCommand $codex $directory $sessionId ([string](Get-UiConfigValue $terminalSession 'CodexModel' ''))
    Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/k',$command) -WorkingDirectory $directory | Out-Null
}

function Start-ProjectCodexConversationRequest {
    param(
        $Project,
        $Session,
        [int]$SessionIndex = -1,
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Origin = 'Desktop',
        [string[]]$ImagePaths = @()
    )
    if($null -eq $Project){return [pscustomobject]@{Started=$false;Error='项目不存在。';Code='project_not_found'}}
    if($null -eq $Session){$Session=Get-ProjectPrimaryCodexSession $Project}
    if($null -eq $Session){return [pscustomobject]@{Started=$false;Error='项目尚未配置会话。';Code='session_not_found'}}
    $conversationProjectId=[string]$Project.Id
    $sessionId=[string](Get-UiConfigValue $Session 'SessionId' '')
    $model=[string](Get-UiConfigValue $Session 'CodexModel' '')
    $description=[string](Get-UiConfigValue $Session 'Description' '无描述')
    if([string]::IsNullOrWhiteSpace($description)){$description='无描述'}
    $processKey=Get-CodexConversationProcessKey 'Project' $conversationProjectId $sessionId $SessionIndex
    Complete-ProjectCodexMessage
    if(Test-CodexConversationProcessBusy $processKey){return [pscustomobject]@{Started=$false;Error='当前会话仍在后台执行或同步中。';Code='conversation_busy';ProcessKey=$processKey}}
    $busyWorkflow=Get-ProjectCodexSessionBusyRecord $Project $sessionId
    if($null-ne$busyWorkflow){return [pscustomobject]@{Started=$false;Error=('该会话正在由工作任务“'+[string]$busyWorkflow.WorkflowName+'”调用。');Code='workflow_busy';ProcessKey=$processKey}}
    $codex=Resolve-ConfiguredPath ([string]$script:GlobalSettings.CodexPath)
    $directory=Resolve-CodexWorkingDirectory ([string]$Project.DefaultWorkingDirectory)
    if(-not [IO.File]::Exists($codex)){return [pscustomobject]@{Started=$false;Error='全局 Codex 路径不存在。';Code='codex_not_found'}}
    if(-not [IO.Directory]::Exists($directory)){return [pscustomobject]@{Started=$false;Error='项目默认工作目录不存在。';Code='working_directory_not_found'}}
    $outputDirectory=Join-Path $script:DataDirectory 'project-conversations';if(-not[IO.Directory]::Exists($outputDirectory)){[IO.Directory]::CreateDirectory($outputDirectory)|Out-Null}
    $outputKey=if([string]::IsNullOrWhiteSpace($sessionId)){if($SessionIndex -ge 0){'_new-'+[string]$SessionIndex}else{'new'}}else{($sessionId-replace'[^A-Za-z0-9_-]','_')}
    $outputPath=Join-Path $outputDirectory ($conversationProjectId+'.'+$outputKey+'.last-response.txt');if(Test-Path -LiteralPath $outputPath){[IO.File]::Delete($outputPath)}
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$codex;$info.Arguments=New-ProjectCodexArguments -SessionId $sessionId -Prompt $Prompt -WorkingDirectory $directory -OutputPath $outputPath -Model $model -ImagePaths $ImagePaths;$info.WorkingDirectory=$directory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    try{$info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8}catch{}
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    $stdoutCapture = $null
    $stderrCapture = $null
    try{
        if(-not $process.Start()){throw '无法启动 Codex。'}
        $stdoutCapture = New-Object -TypeName WorkflowProcessStreamCapture -ArgumentList @($process.StandardOutput, 8000000)
        $stderrCapture = New-Object -TypeName WorkflowProcessStreamCapture -ArgumentList @($process.StandardError, 2000000)
        $record=[pscustomobject]@{Key=$processKey;Process=$process;Mode='Project';Origin=$Origin;ProjectId=$conversationProjectId;SessionId=$sessionId;InitialSessionId=$sessionId;SessionIndex=$SessionIndex;SessionDescription=$description;SessionModel=$model;Model=$model;WorkingDirectory=$directory;OutputPath=$outputPath;PendingPrompt=$Prompt;StdOut=$stdoutCapture;StdErr=$stderrCapture;StartedAt=Get-Date;StopRequested=$false;TerminationReason='Running';FinalizeState='Running';ExitObservedAt=$null;OutputDrainDeadline=$null}
        $script:CodexConversationProcesses[$processKey]=$record
        if($Origin -eq 'Desktop'){$script:CodexConversationProcess=$record}
        if($null -ne $script:CodexConversationTimer){$script:CodexConversationTimer.Start()}
        if($Origin -eq 'Desktop'){Update-CodexConversationControls}
        $startedSessionKey=if([string]::IsNullOrWhiteSpace($sessionId)){('_new-'+[string]$SessionIndex)}else{$sessionId}
        return [pscustomobject]@{Started=$true;ProcessKey=$processKey;ProjectId=$conversationProjectId;SessionId=$sessionId;SessionKey=$startedSessionKey;Description=$description;Model=$model;StartedAt=$record.StartedAt}
    }catch{
        try { if ($null -ne $stdoutCapture) { $stdoutCapture.Dispose() } } catch { }
        try { if ($null -ne $stderrCapture) { $stderrCapture.Dispose() } } catch { }
        try{$process.Dispose()}catch{}
        return [pscustomobject]@{Started=$false;Error=('启动 Codex 失败：'+$_.Exception.Message);Code='codex_start_failed';ProcessKey=$processKey}
    }
}

function Send-ProjectCodexMessage {
    if($null -eq $script:CurrentProject){return}
    Complete-ProjectCodexMessage
    $conversationProjectId=[string]$script:CodexConversationProjectId;if([string]::IsNullOrWhiteSpace($conversationProjectId)){$conversationProjectId=[string]$script:CurrentProject.Id}
    $conversationProject=Get-ProjectById $conversationProjectId
    if($null-eq$conversationProject){return}
    $sessionId=[string]$script:CodexConversationSessionId
    $model=[string]$script:CodexConversationSessionModel
    $typedPrompt=$script:CodexConversationInput.Text.Trim();$attachments=@($script:CodexConversationPendingImages);$prompt=Get-CodexConversationPromptWithImages $typedPrompt $attachments
    if([string]::IsNullOrWhiteSpace($prompt)){return}
    $configuredSessions=@(Get-ProjectCodexSessions $conversationProject);$sessionIndex=-1;$selectedSession=$null
    for($i=0;$i-lt$configuredSessions.Count;$i++){
        $candidate=$configuredSessions[$i]
        if([string]$candidate.SessionId-eq$sessionId-and[string]$candidate.Description-eq[string]$script:CodexConversationSessionDescription-and[string]$candidate.CodexModel-eq$model){$sessionIndex=$i;$selectedSession=$candidate;break}
    }
    if($null-eq$selectedSession -and $configuredSessions.Count-gt0){$selectedSession=if($sessionIndex-ge0){$configuredSessions[$sessionIndex]}else{$configuredSessions[0]};$sessionIndex=if($sessionIndex-ge0){$sessionIndex}else{0}}
    $started=Start-ProjectCodexConversationRequest $conversationProject $selectedSession $sessionIndex $prompt 'Desktop' @($attachments|ForEach-Object{[string]$_.Path})
    if(-not $started.Started){Set-CodexConversationStatus ([string]$started.Error) 'Error';Update-CodexConversationControls;return}
    Add-CodexConversationMessage 'user' $prompt
    Add-CodexMessageToSnapshot $sessionId 'user' $prompt
    $script:CodexConversationInput.Clear();Clear-CodexConversationPendingImages -KeepFiles;$script:CodexConversationSend.Enabled=$false;$script:CodexConversationInput.Enabled=$false
    Set-CodexConversationStatus $(if([string]::IsNullOrWhiteSpace($sessionId)){'正在创建项目会话并等待 Codex 回复...'}else{'正在恢复会话并等待 Codex 回复...'}) 'Busy'
    return
}

function Send-WorkflowAiMessage {
    Complete-ProjectCodexMessage
    $processKey=Get-CodexConversationProcessKey 'WorkflowAi' ''
    if(Test-CodexConversationProcessBusy $processKey){Set-CodexConversationStatus '使驾 AI 仍在后台执行或同步中' 'Busy';return}
    $typedPrompt=$script:CodexConversationInput.Text.Trim();$attachments=@($script:CodexConversationPendingImages);$userPrompt=Get-CodexConversationPromptWithImages $typedPrompt $attachments;if([string]::IsNullOrWhiteSpace($userPrompt)){return}
    $codex=Resolve-ConfiguredPath ([string]$script:GlobalSettings.CodexPath)
    if(-not[IO.File]::Exists($codex)){Show-Message '全局 Codex 路径不存在。' '使驾 AI' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    Ensure-DataDirectories
    $workflowAiWorkingDirectory=Resolve-CodexWorkingDirectory $script:WorkflowAiDirectory ([IO.Path]::GetTempPath())
    if([string]::IsNullOrWhiteSpace($workflowAiWorkingDirectory)){Show-Message '使驾 AI 工作目录无效，无法启动 Codex。' '使驾 AI' ([Windows.Forms.MessageBoxIcon]::Warning);return}
    $prompt=Get-WorkflowAiPrompt $userPrompt
    $sessionId=[string]$script:GlobalSettings.WorkflowAiSessionId
    $outputPath=Join-Path $script:WorkflowAiDirectory 'last-response.txt'
    if(Test-Path -LiteralPath $outputPath){[IO.File]::Delete($outputPath)}
    Add-CodexConversationMessage 'user' $userPrompt
    Add-CodexMessageToSnapshot $sessionId 'user' $userPrompt
    $script:CodexConversationInput.Clear();Clear-CodexConversationPendingImages -KeepFiles;$script:CodexConversationSend.Enabled=$false;$script:CodexConversationInput.Enabled=$false
    $busyText=if([string]::IsNullOrWhiteSpace($sessionId)){'正在创建独立会话...'}else{'正在恢复独立会话...'}
    Set-CodexConversationStatus $busyText 'Busy'
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$codex;$info.Arguments=New-WorkflowAiCodexArguments -SessionId $sessionId -Prompt $prompt -OutputPath $outputPath -ImagePaths @($attachments|ForEach-Object{[string]$_.Path});$info.WorkingDirectory=$workflowAiWorkingDirectory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    try{$info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8}catch{}
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    $stdoutCapture = $null
    $stderrCapture = $null
    try{
        if(-not$process.Start()){throw '无法启动 Codex。'}
        $stdoutCapture = New-Object -TypeName WorkflowProcessStreamCapture -ArgumentList @($process.StandardOutput, 8000000)
        $stderrCapture = New-Object -TypeName WorkflowProcessStreamCapture -ArgumentList @($process.StandardError, 2000000)
        $record=[pscustomobject]@{Key=$processKey;Process=$process;Mode='WorkflowAi';ProjectId='';SessionId=$sessionId;WorkingDirectory=$workflowAiWorkingDirectory;StdOut=$stdoutCapture;StdErr=$stderrCapture;OutputPath=$outputPath;InitialSessionId=$sessionId;StartedAt=Get-Date;StopRequested=$false;TerminationReason='Running';FinalizeState='Running';ExitObservedAt=$null;OutputDrainDeadline=$null}
        $script:CodexConversationProcesses[$processKey]=$record;$script:CodexConversationProcess=$record
        $script:CodexConversationTimer.Start();Update-CodexConversationControls
    }catch{
        try { if ($null -ne $stdoutCapture) { $stdoutCapture.Dispose() } } catch { }
        try { if ($null -ne $stderrCapture) { $stderrCapture.Dispose() } } catch { }
        Add-CodexConversationMessage 'assistant' ("启动失败：$($_.Exception.Message)");Set-CodexConversationStatus '启动失败' 'Error';$script:CodexConversationSend.Enabled=$true;$script:CodexConversationInput.Enabled=$true;$process.Dispose()
    }
}

function Send-CodexConversationMessage {
    if($script:CodexConversationMode -eq 'WorkflowAi'){Send-WorkflowAiMessage}else{Send-ProjectCodexMessage}
}

function Finalize-CodexConversationRecord {
    param([string]$Key, $Record, [string]$StdOut, [string]$StdErr, [int]$ExitCode)
    $key = $Key
    $record = $Record
    $stdout = $StdOut
    $stderr = $StdErr
        $recordMode = [string](Get-UiConfigValue $record 'Mode' 'Project')
        $sessionId = [string](Get-UiConfigValue $record 'SessionId' '')
        $stopRequested = [bool](Get-UiConfigValue $record 'StopRequested' $false)
        $completionObserved = [bool](Get-UiConfigValue $record 'CompletionObserved' $false)
        $answer = ''
        $createdWorkflowAiSession = $false
        $createdProjectSession = $false
        $projectSessionBindingFailed = $false
        if ($recordMode -eq 'WorkflowAi') {
            $newSessionId = Get-CodexJsonSessionId $stdout
            if ([string]::IsNullOrWhiteSpace([string]$script:GlobalSettings.WorkflowAiSessionId) -and -not [string]::IsNullOrWhiteSpace($newSessionId)) {
                $script:GlobalSettings.WorkflowAiSessionId = $newSessionId
                Save-GlobalSettings
                $sessionId = $newSessionId
                $record.SessionId = $newSessionId
                $script:CodexSessionCache = @()
                $script:CodexSessionCacheAt = [datetime]::MinValue
                $createdWorkflowAiSession = $true
            }
            if ($null -ne $record.PSObject.Properties['OutputPath'] -and -not [string]::IsNullOrWhiteSpace([string]$record.OutputPath) -and (Test-Path -LiteralPath ([string]$record.OutputPath))) {
                try { $answer = Read-TextFileWithRetry ([string]$record.OutputPath) 1000 4194304 } catch { }
            }
        } else {
            $newSessionId = Get-CodexJsonSessionId $stdout
            $project = Get-ProjectById ([string](Get-UiConfigValue $record 'ProjectId' ''))
            if ($null -ne $project -and [string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $record 'InitialSessionId' '')) -and -not [string]::IsNullOrWhiteSpace($newSessionId)) {
                $newDescription=[string](Get-UiConfigValue $record 'SessionDescription' '无描述');if([string]::IsNullOrWhiteSpace($newDescription)){$newDescription='无描述'}
                $newModel=[string](Get-UiConfigValue $record 'SessionModel' (Get-UiConfigValue $record 'Model' ''))
                $projectSessions=@(Get-ProjectCodexSessions $project)
                $replacementIndex=-1
                $recordSessionIndex=[int](Get-UiConfigValue $record 'SessionIndex' -1)
                if($recordSessionIndex-ge0-and$recordSessionIndex-lt$projectSessions.Count-and[string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $projectSessions[$recordSessionIndex] 'SessionId' ''))){$replacementIndex=$recordSessionIndex}
                for($sessionIndex=0;$sessionIndex-lt$projectSessions.Count;$sessionIndex++){
                    $candidate=$projectSessions[$sessionIndex]
                    if($replacementIndex-lt0-and[string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $candidate 'SessionId' ''))){
                        $candidateDescription=[string](Get-UiConfigValue $candidate 'Description' '无描述');if([string]::IsNullOrWhiteSpace($candidateDescription)){$candidateDescription='无描述'}
                        $candidateModel=[string](Get-UiConfigValue $candidate 'CodexModel' '')
                        if($candidateDescription-eq$newDescription-and$candidateModel-eq$newModel){$replacementIndex=$sessionIndex;break}
                    }
                }
                if($replacementIndex-lt0){
                    $emptyIndexes=@()
                    for($sessionIndex=0;$sessionIndex-lt$projectSessions.Count;$sessionIndex++){if([string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $projectSessions[$sessionIndex] 'SessionId' ''))){$emptyIndexes+= $sessionIndex}}
                    if($emptyIndexes.Count-eq1){$replacementIndex=[int]$emptyIndexes[0]}
                }
                $newSessionEntry=[pscustomobject]@{SessionId=$newSessionId;CodexModel=$newModel;Description=$newDescription}
                if($replacementIndex-ge0){$projectSessions[$replacementIndex]=$newSessionEntry}else{$projectSessions=@($projectSessions)+@($newSessionEntry)}
                Set-ProjectCodexSessions $project $projectSessions
                $project.UpdatedAt = (Get-Date).ToString('o')
                Save-Projects
                $sessionId = $newSessionId
                $record.SessionId = $newSessionId
                $script:CodexSessionCache = @()
                $script:CodexSessionCacheAt = [datetime]::MinValue
                $createdProjectSession = $true
                if ($null -ne $script:CurrentProject -and [string]$script:CurrentProject.Id -eq [string]$project.Id) { $script:CurrentProject = $project; Update-ProjectInfo }
                if($script:CodexConversationMode-eq'Project'-and[string]$script:CodexConversationProjectId-eq[string]$project.Id-and[string]::IsNullOrWhiteSpace($script:CodexConversationSessionId)){
                    $script:CodexConversationSessionId=$newSessionId;$script:CodexConversationSessionDescription=$newDescription;$script:CodexConversationSessionModel=$newModel
                    Update-CodexConversationProjectHeader $project
                }
            }
            elseif ($null -ne $project -and [string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $record 'InitialSessionId' ''))) { $projectSessionBindingFailed = $true }
            if ($null -ne $record.PSObject.Properties['OutputPath'] -and -not [string]::IsNullOrWhiteSpace([string]$record.OutputPath) -and (Test-Path -LiteralPath ([string]$record.OutputPath))) {
                try { $answer = Read-TextFileWithRetry ([string]$record.OutputPath) 1000 4194304 } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($answer) -and -not [string]::IsNullOrWhiteSpace($stdout) -and [string]::IsNullOrWhiteSpace([string](Get-UiConfigValue $record 'OutputPath' ''))) { $answer = $stdout }
        }
        if (-not [string]::IsNullOrWhiteSpace($answer)) { Add-CodexMessageToSnapshot $sessionId 'assistant' $answer.Trim() -SkipIfLast }
        $isVisible = $null -ne $script:CodexConversationPanel -and $script:CodexConversationPanel.Visible -and (((Get-CurrentCodexConversationProcessKey) -eq $key)-or($createdProjectSession-and$script:CodexConversationMode-eq'Project'-and[string]$script:CodexConversationProjectId-eq[string](Get-UiConfigValue $record 'ProjectId' '')-and[string]$script:CodexConversationSessionId-eq$sessionId))
        if ($isVisible) {
            if ($createdWorkflowAiSession) { Load-CodexConversationSession $sessionId '使驾 AI' -Refresh -Incremental }
            elseif ($createdProjectSession -and -not [string]::IsNullOrWhiteSpace($sessionId)) { Load-CodexConversationSession $sessionId ([string](Get-UiConfigValue (Get-ProjectById ([string]$record.ProjectId)) 'Name' '项目会话')) -Refresh -Incremental }
            else { Refresh-CodexConversation -Automatic }
            if (-not [string]::IsNullOrWhiteSpace($answer) -and $script:CodexConversationOutput.Text.IndexOf($answer.Trim(), [StringComparison]::Ordinal) -lt 0) { Add-CodexConversationMessage 'assistant' $answer.Trim() }
            if ($stopRequested) {
                Set-CodexConversationStatus '会话已手动停止'
            } else {
                if ($ExitCode -ne 0 -and -not $completionObserved) {
                    if(-not[string]::IsNullOrWhiteSpace($stderr)){
                        $diagnostic=$stderr.Trim();if($diagnostic.Length-gt2000){$diagnostic=$diagnostic.Substring(0,2000)+'...'}
                        Write-WorkflowLog ('Codex 会话错误输出（未显示在对话中）：'+$diagnostic) 'ERROR'
                    }
                    $workingDirectory=[string](Get-UiConfigValue $record 'WorkingDirectory' '')
                    Write-WorkflowLog ('Codex 进程自行退出（使驾未发送停止请求）：退出码 '+$ExitCode+'；工作目录：'+$workingDirectory) 'ERROR'
                    Set-CodexConversationStatus ("Codex 自行退出，退出码 " + $ExitCode) 'Error'
                }
                elseif ($projectSessionBindingFailed) { Set-CodexConversationStatus '回复完成，但未能识别并绑定新会话 ID' 'Error' }
                else { Set-CodexConversationStatus '回复完成 · 历史已同步' }
            }
        }
}

function Complete-ProjectCodexMessage {
    foreach ($key in @($script:CodexConversationProcesses.Keys)) {
        if (-not $script:CodexConversationProcesses.ContainsKey($key)) { continue }
        $record = $script:CodexConversationProcesses[$key]
        if ($null -eq $record) { $script:CodexConversationProcesses.Remove($key); continue }
        $isVisible = $null -ne $script:CodexConversationPanel -and $script:CodexConversationPanel.Visible -and ((Get-CurrentCodexConversationProcessKey) -eq $key)
        $processExited = $false
        $processStateError = $null
        try {
            $processExited = [bool]$record.Process.HasExited
        } catch {
            $processStateError = $_.Exception.Message
        }
        $outputReady = Test-CodexConversationOutputReady $record
        if (-not $processExited -and -not $outputReady) {
            if (-not [string]::IsNullOrWhiteSpace($processStateError)) {
                Write-WorkflowLog ('Codex 会话进程状态读取失败，暂不清理状态：' + $processStateError) 'WARN'
            }
            continue
        }
        if ($outputReady -and -not $processExited) {
            Set-CodexConversationRecordValue $record 'CompletionObserved' $true
            Set-CodexConversationRecordValue $record 'CompletionSignal' 'OutputFile'
            Write-WorkflowLog ('Codex 已生成完整回复文件，但宿主进程仍未退出，开始收尾清理：' + [string](Get-UiConfigValue $record 'OutputPath' '')) 'WARN'
            try {
                Stop-WorkflowProcessTree ([int]$record.Process.Id)
                [void]$record.Process.WaitForExit(1500)
            } catch { }
            try { $processExited = [bool]$record.Process.HasExited } catch { }
        }

        $finalizeState = [string](Get-UiConfigValue $record 'FinalizeState' 'Running')
        if ($finalizeState -in @('Finalizing','Finalized')) { continue }
        $now = Get-Date
        if ($finalizeState -eq 'Running') {
            Set-CodexConversationRecordValue $record 'FinalizeState' 'DrainingOutput'
            Set-CodexConversationRecordValue $record 'ExitObservedAt' $now
            Set-CodexConversationRecordValue $record 'OutputDrainDeadline' $now.AddSeconds([Math]::Max(1, [double]$script:CodexConversationOutputDrainTimeoutSeconds))
            if ($isVisible) { Set-CodexConversationStatus 'Codex 已退出，正在同步回复...' 'Busy' }
        }

        $deadline = $now.AddSeconds([Math]::Max(1, [double]$script:CodexConversationOutputDrainTimeoutSeconds))
        $deadlineValue = Get-UiConfigValue $record 'OutputDrainDeadline' $null
        if ($null -ne $deadlineValue) { try { $deadline = [datetime]$deadlineValue } catch { } }
        $forceDrain = $outputReady -or $now -ge $deadline
        $stdoutState = Get-CodexConversationOutputTaskState (Get-UiConfigValue $record 'StdOut' $null) 'stdout' -Force:$forceDrain
        $stderrState = Get-CodexConversationOutputTaskState (Get-UiConfigValue $record 'StdErr' $null) 'stderr' -Force:$forceDrain
        if (-not [bool]$stdoutState.Completed -or -not [bool]$stderrState.Completed) {
            if ($isVisible) { Set-CodexConversationStatus 'Codex 已退出，正在同步回复...' 'Busy' }
            continue
        }

        Set-CodexConversationRecordValue $record 'FinalizeState' 'Finalizing'
        $exitCode = -1
        try { $exitCode = [int]$record.Process.ExitCode } catch { }
        try {
            foreach ($outputError in @([string]$stdoutState.Error, [string]$stderrState.Error)) {
                if (-not [string]::IsNullOrWhiteSpace($outputError)) { Write-WorkflowLog ('Codex 会话收尾提示：' + $outputError + '；将继续恢复界面操作。') 'WARN' }
            }
            Finalize-CodexConversationRecord $key $record ([string]$stdoutState.Text) ([string]$stderrState.Text) $exitCode
        } catch {
            Write-WorkflowLog ('Codex 会话收尾失败，已强制恢复界面操作：' + $_.Exception.Message) 'ERROR'
            if ($isVisible) { Set-CodexConversationStatus ('会话收尾失败：' + $_.Exception.Message) 'Error' }
        } finally {
            Set-CodexConversationRecordValue $record 'FinalizeState' 'Finalized'
            try { Dispose-CodexConversationOutputCapture $record } catch { }
            try { $record.Process.Dispose() } catch { }
            $script:CodexConversationProcesses.Remove($key)
            if ($script:CodexConversationProcess -eq $record) { $script:CodexConversationProcess = $null }
        }
    }
    if ($null -ne $script:CodexConversationPanel -and $script:CodexConversationPanel.Visible) {
        $currentKey = Get-CurrentCodexConversationProcessKey
        $hasSession = if($script:CodexConversationMode -eq 'WorkflowAi'){-not[string]::IsNullOrWhiteSpace([string]$script:GlobalSettings.WorkflowAiSessionId)}else{$visibleProject=Get-ProjectById $script:CodexConversationProjectId;$null-ne$visibleProject-and-not[string]::IsNullOrWhiteSpace([string]$script:CodexConversationSessionId)}
        if ($hasSession -and (Test-CodexConversationProcessRunning $currentKey) -and ((Get-Date) - $script:CodexConversationLastAutoRefreshAt).TotalMilliseconds -ge 1000) {
            $script:CodexConversationLastAutoRefreshAt = Get-Date; Refresh-CodexConversation -Automatic
        }
        Update-CodexConversationControls
    }
    if ($script:CodexConversationProcesses.Count -eq 0 -and $null -ne $script:CodexConversationTimer) { $script:CodexConversationTimer.Stop() }
}

function Get-SelectedScheduleMode {
    if ($null -eq $script:ScheduleModeBox -or $null -eq $script:ScheduleModeBox.SelectedItem) { return 'Loop' }
    return [string]$script:ScheduleModeBox.SelectedItem.Value
}

function Get-SelectedScheduleKind {
    if ($null -eq $script:ScheduleKindBox -or $null -eq $script:ScheduleKindBox.SelectedItem) { return 'Interval' }
    return [string]$script:ScheduleKindBox.SelectedItem.Value
}

function Set-ScheduleKindOptions {
    param([string]$Mode, [string]$SelectedKind = 'Interval')
    $options = if ($Mode -eq 'Once') {
        @([pscustomobject]@{ Text = '间隔分钟'; Value = 'Interval' }, [pscustomobject]@{ Text = '下一个时间'; Value = 'NextTime' })
    } else {
        @(
            [pscustomobject]@{ Text = '间隔分钟'; Value = 'Interval' }
            [pscustomobject]@{ Text = '每日'; Value = 'Daily' }
            [pscustomobject]@{ Text = '每周'; Value = 'Weekly' }
            [pscustomobject]@{ Text = '每月'; Value = 'Monthly' }
        )
    }
    $script:ScheduleKindBox.BeginUpdate()
    $script:ScheduleKindBox.Items.Clear()
    $selectedIndex = 0
    for ($index = 0; $index -lt $options.Count; $index++) {
        [void]$script:ScheduleKindBox.Items.Add($options[$index])
        if ($options[$index].Value -eq $SelectedKind) { $selectedIndex = $index }
    }
    $script:ScheduleKindBox.SelectedIndex = $selectedIndex
    $script:ScheduleKindBox.EndUpdate()
}

function Update-ScheduleEditorVisibility {
    $kind = Get-SelectedScheduleKind
    $showInterval = $kind -eq 'Interval'
    $showTime = $kind -in @('Daily','Weekly','Monthly','NextTime')
    $showWeekdays = $kind -eq 'Weekly'
    $showDay = $kind -eq 'Monthly'
    $script:IntervalLabel.Visible = $showInterval
    $script:IntervalBox.Visible = $showInterval
    $script:ScheduleTimeLabel.Visible = $showTime
    $script:ScheduleTimeBox.Visible = $showTime
    $script:ScheduleWeekdaysLabel.Visible = $showWeekdays
    $script:ScheduleWeekdaysBox.Visible = $showWeekdays
    $script:ScheduleDayLabel.Visible = $showDay
    $script:ScheduleDayBox.Visible = $showDay
}

function Sync-WorkflowScheduleFromControls {
    param([switch]$Validate)
    if ($script:BindingWorkflow -or $null -eq $script:CurrentWorkflow) { return }
    $mode = Get-SelectedScheduleMode
    $kind = Get-SelectedScheduleKind
    $script:CurrentWorkflow.ScheduleMode = $mode
    $script:CurrentWorkflow.ScheduleKind = $kind
    $script:CurrentWorkflow.IntervalMinutes = [int]$script:IntervalBox.Value
    $script:CurrentWorkflow.ScheduleTime = $script:ScheduleTimeBox.Text.Trim()
    $script:CurrentWorkflow.ScheduleWeekdays = $script:ScheduleWeekdaysBox.Text.Trim()
    $script:CurrentWorkflow.ScheduleDayOfMonth = [int]$script:ScheduleDayBox.Value
    if ($Validate -and $kind -in @('Daily','Weekly','Monthly','NextTime')) { [void](ConvertTo-ScheduleTimeSpan $script:CurrentWorkflow.ScheduleTime -ThrowOnInvalid) }
    if ($Validate -and $kind -eq 'Weekly') { $null = @(Get-ScheduleWeekdays $script:CurrentWorkflow.ScheduleWeekdays -ThrowOnInvalid) }
    $script:CurrentWorkflow.NextRunUtc = (Get-NextWorkflowRunUtc $script:CurrentWorkflow ([datetime]::UtcNow) -Validate:$Validate).ToString('o')
    Update-WorkflowNextRunLabel
}

function Show-WorkflowScheduleEditor {
    if ($null -eq $script:CurrentWorkflow) { return }
    $workflow = $script:CurrentWorkflow
    $form = New-Object Windows.Forms.Form
    Set-WorkflowFormScaling $form
    $form.Text = '定时配置 - ' + [string]$workflow.Name
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(520, 350)
    $form.Font = New-UiFont 9
    Set-WorkflowWindowIcon $form
    $form.Add_HandleCreated({ param($sender,$eventArgs) Set-WorkflowWindowIcon $sender })

    Add-UiLabel $form '执行模式' 28 30 90 24 | Out-Null
    $modeBox = New-Object Windows.Forms.ComboBox
    $modeBox.Location = New-Object Drawing.Point(128,27); $modeBox.Size = New-Object Drawing.Size(160,28); $modeBox.DropDownStyle='DropDownList'; $modeBox.DisplayMember='Text'; $modeBox.ValueMember='Value'
    [void]$modeBox.Items.Add([pscustomobject]@{Text='循环执行';Value='Loop'}); [void]$modeBox.Items.Add([pscustomobject]@{Text='执行一次';Value='Once'}); $form.Controls.Add($modeBox)
    Add-UiLabel $form '定时规则' 28 78 90 24 | Out-Null
    $kindBox = New-Object Windows.Forms.ComboBox
    $kindBox.Location = New-Object Drawing.Point(128,75); $kindBox.Size = New-Object Drawing.Size(160,28); $kindBox.DropDownStyle='DropDownList'; $kindBox.DisplayMember='Text'; $kindBox.ValueMember='Value'; $form.Controls.Add($kindBox)
    $intervalLabel = Add-UiLabel $form '间隔分钟' 28 126 90 24
    $intervalBox = New-Object Windows.Forms.NumericUpDown; $intervalBox.Location=New-Object Drawing.Point(128,123); $intervalBox.Size=New-Object Drawing.Size(160,28); $intervalBox.Minimum=1; $intervalBox.Maximum=10080; $intervalBox.Value=[Math]::Min(10080,[Math]::Max(1,[int](Get-UiConfigValue $workflow 'IntervalMinutes' 60))); $form.Controls.Add($intervalBox)
    $timeLabel = Add-UiLabel $form '执行时间' 28 126 90 24
    $initialScheduleTime=[string](Get-UiConfigValue $workflow 'ScheduleTime' '09:00:00')
    if([string]::IsNullOrWhiteSpace($initialScheduleTime)){$initialScheduleTime='09:00:00'}
    $timeBox = New-Object Windows.Forms.TextBox; $timeBox.Location=New-Object Drawing.Point(128,123); $timeBox.Size=New-Object Drawing.Size(160,28); $timeBox.Text=$initialScheduleTime; $form.Controls.Add($timeBox)
    $weekdaysLabel = Add-UiLabel $form '周几（1-7）' 28 174 90 24
    $weekdaysBox = New-Object Windows.Forms.TextBox; $weekdaysBox.Location=New-Object Drawing.Point(128,171); $weekdaysBox.Size=New-Object Drawing.Size(160,28); $weekdaysBox.Text=[string](Get-UiConfigValue $workflow 'ScheduleWeekdays' '1'); $form.Controls.Add($weekdaysBox)
    $dayLabel = Add-UiLabel $form '每月几号' 28 174 90 24
    $dayBox = New-Object Windows.Forms.NumericUpDown; $dayBox.Location=New-Object Drawing.Point(128,171); $dayBox.Size=New-Object Drawing.Size(160,28); $dayBox.Minimum=1; $dayBox.Maximum=31; $dayBox.Value=[Math]::Min(31,[Math]::Max(1,[int](Get-UiConfigValue $workflow 'ScheduleDayOfMonth' 1))); $form.Controls.Add($dayBox)
    $hint = Add-UiLabel $form '' 28 220 460 50 -Muted
    $save = Add-UiButton $form '保存配置' 306 294 96 34 'Primary'
    $cancel = Add-UiButton $form '取消' 412 294 76 34
    $cancel.Add_Click({$form.DialogResult='Cancel';$form.Close()})

    $setKindOptions = {
        param([string]$Mode,[string]$SelectedKind)
        $options = if($Mode-eq'Once'){@([pscustomobject]@{Text='间隔分钟';Value='Interval'},[pscustomobject]@{Text='下一个时间';Value='NextTime'})}else{@([pscustomobject]@{Text='间隔分钟';Value='Interval'},[pscustomobject]@{Text='每日';Value='Daily'},[pscustomobject]@{Text='每周';Value='Weekly'},[pscustomobject]@{Text='每月';Value='Monthly'})}
        $kindBox.BeginUpdate();$kindBox.Items.Clear();$selectedIndex=0
        for($index=0;$index-lt$options.Count;$index++){[void]$kindBox.Items.Add($options[$index]);if([string]$options[$index].Value-eq$SelectedKind){$selectedIndex=$index}}
        $kindBox.SelectedIndex=$selectedIndex;$kindBox.EndUpdate()
    }
    $updateVisibility = {
        $kind=if($null-eq$kindBox.SelectedItem){'Interval'}else{[string]$kindBox.SelectedItem.Value}
        $intervalLabel.Visible=$kind-eq'Interval';$intervalBox.Visible=$kind-eq'Interval'
        $timeLabel.Visible=$kind-in@('Daily','Weekly','Monthly','NextTime');$timeBox.Visible=$timeLabel.Visible
        $weekdaysLabel.Visible=$kind-eq'Weekly';$weekdaysBox.Visible=$kind-eq'Weekly'
        $dayLabel.Visible=$kind-eq'Monthly';$dayBox.Visible=$kind-eq'Monthly'
        $hint.Text=switch($kind){'Interval'{'从保存时刻开始，按设置的分钟数执行。'}'Daily'{'每天在指定时分秒执行。'}'Weekly'{'周一为 1、周日为 7，多个日期使用逗号分隔。'}'Monthly'{'若当月没有该日期，则在当月最后一天执行。'}default{'在下一个指定时分秒执行一次，完成后自动关闭定时。'}}
    }
    $mode=[string](Get-UiConfigValue $workflow 'ScheduleMode' 'Loop');$modeBox.SelectedIndex=if($mode-eq'Once'){1}else{0}
    & $setKindOptions $mode ([string](Get-UiConfigValue $workflow 'ScheduleKind' 'Interval'))
    & $updateVisibility
    $refreshInitialState={
        $timeBox.Text=$initialScheduleTime
        & $updateVisibility
        $form.PerformLayout()
        $timeBox.Invalidate()
        $timeBox.Update()
    }.GetNewClosure()
    & $refreshInitialState
    $form.Add_Shown($refreshInitialState)
    $modeBox.Add_SelectedIndexChanged({$selectedMode=[string]$modeBox.SelectedItem.Value;& $setKindOptions $selectedMode 'Interval';& $updateVisibility})
    $kindBox.Add_SelectedIndexChanged({& $updateVisibility})
    $save.Add_Click({
        try {
            $candidate=[pscustomobject]@{ScheduleMode=[string]$modeBox.SelectedItem.Value;ScheduleKind=[string]$kindBox.SelectedItem.Value;IntervalMinutes=[int]$intervalBox.Value;ScheduleTime=$timeBox.Text.Trim();ScheduleWeekdays=$weekdaysBox.Text.Trim();ScheduleDayOfMonth=[int]$dayBox.Value}
            if($candidate.ScheduleKind-in@('Daily','Weekly','Monthly','NextTime')){[void](ConvertTo-ScheduleTimeSpan $candidate.ScheduleTime -ThrowOnInvalid)}
            if($candidate.ScheduleKind-eq'Weekly'){$null=@(Get-ScheduleWeekdays $candidate.ScheduleWeekdays -ThrowOnInvalid)}
            $next=(Get-NextWorkflowRunUtc $candidate ([datetime]::UtcNow) -Validate).ToString('o')
            foreach($name in @('ScheduleMode','ScheduleKind','IntervalMinutes','ScheduleTime','ScheduleWeekdays','ScheduleDayOfMonth')){$workflow.$name=$candidate.$name}
            $workflow.NextRunUtc=$next
            $form.DialogResult='OK';$form.Close()
        }catch{Show-Message $_.Exception.Message '定时配置无效' ([Windows.Forms.MessageBoxIcon]::Warning)}
    })
    Apply-UiTheme $form
    & $refreshInitialState
    $scheduleDialogResult=$null
    try{$scheduleDialogResult=$form.ShowDialog($script:MainForm)}finally{if($null-ne$form-and-not$form.IsDisposed){$form.Dispose()}}
    if($scheduleDialogResult-eq'OK'){
        $script:BindingWorkflow=$true
        $mode=[string](Get-UiConfigValue $workflow 'ScheduleMode' 'Loop');$script:ScheduleModeBox.SelectedIndex=if($mode-eq'Once'){1}else{0};Set-ScheduleKindOptions $mode ([string](Get-UiConfigValue $workflow 'ScheduleKind' 'Interval'));$script:ScheduleTimeBox.Text=[string]$workflow.ScheduleTime;$script:ScheduleWeekdaysBox.Text=[string]$workflow.ScheduleWeekdays;$script:ScheduleDayBox.Value=[int]$workflow.ScheduleDayOfMonth;$script:IntervalBox.Value=[int]$workflow.IntervalMinutes
        $script:BindingWorkflow=$false
        Update-ScheduleEditorVisibility;Update-WorkflowNextRunLabel;Save-Workflows
    }
}

function Bind-CurrentWorkflow {
    if ($null -eq $script:WorkflowList -or $script:WorkflowList.SelectedIndex -lt 0) { return }
    $freezeCanvas=$null-ne$script:Canvas-and-not$script:Canvas.IsDisposed
    if($freezeCanvas){[WorkflowNativeMethods]::SetControlRedraw($script:Canvas,$false)}
    $script:BindingWorkflow = $true
    try {
        Show-WorkflowWorkspace
        $script:CurrentWorkflow = $script:WorkflowList.SelectedItem
        $script:WorkflowNameBox.Text = [string]$script:CurrentWorkflow.Name
        $script:WorkflowEnabled.Checked = [bool]$script:CurrentWorkflow.Enabled
        $mode = [string](Get-UiConfigValue $script:CurrentWorkflow 'ScheduleMode' 'Loop')
        $script:ScheduleModeBox.SelectedIndex = if ($mode -eq 'Once') { 1 } else { 0 }
        Set-ScheduleKindOptions $mode ([string](Get-UiConfigValue $script:CurrentWorkflow 'ScheduleKind' 'Interval'))
        $script:ScheduleTimeBox.Text = [string](Get-UiConfigValue $script:CurrentWorkflow 'ScheduleTime' '09:00:00')
        $script:ScheduleWeekdaysBox.Text = [string](Get-UiConfigValue $script:CurrentWorkflow 'ScheduleWeekdays' '1')
        $script:ScheduleDayBox.Value = [Math]::Min(31, [Math]::Max(1, [int](Get-UiConfigValue $script:CurrentWorkflow 'ScheduleDayOfMonth' 1)))
        $minutes = [Math]::Min(10080, [Math]::Max(1, [int]$script:CurrentWorkflow.IntervalMinutes))
        $script:IntervalBox.Value = $minutes
        $script:SelectedNode = $null
        $script:SelectedEdge = $null
        Update-ScheduleEditorVisibility
        Update-WorkflowNextRunLabel
        Update-CanvasExtent
        $script:Canvas.Invalidate()
    } finally {
        $script:BindingWorkflow = $false
        if($freezeCanvas){[WorkflowNativeMethods]::SetControlRedraw($script:Canvas,$true)}
    }
}

function Show-WorkflowManager {
    $script:AllowExit = $false
    $script:Exiting = $false
    try { [void][WorkflowNativeMethods]::SetCurrentProcessExplicitAppUserModelID('Shijia.WorkflowManager') } catch { }
    $form = New-Object WorkflowMainForm
    Set-WorkflowFormScaling $form
    $script:MainForm = $form
    $form.Text = $script:AppName
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(1080, 680)
    $form.ClientSize = New-Object System.Drawing.Size(1280, 820)
    $form.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = New-UiFont 9
    $form.KeyPreview = $true
    Set-WorkflowWindowIcon $form
    $form.Add_HandleCreated({ Set-WorkflowWindowIcon $script:MainForm })
    $form.Add_DpiChanged({
        Set-WorkflowWindowIcon $script:MainForm; Register-WorkflowTrayIcon -Refresh
        $script:CodexConversationOutputLayoutWidth=0;$script:CodexConversationOutputLayoutDpi=0
        foreach($record in @($script:CodexConversationBubbleRecords)){if($null-ne$record){$record.LayoutKey=''}}
        if($null-ne$script:MainForm-and$script:MainForm.IsHandleCreated){
            try{[void]$script:MainForm.BeginInvoke([Action]{Update-CodexConversationComposerHeight;[void](Resize-CodexConversationBubbles -Force)})}catch{}
        }
    })

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'; $header.Height = 58; $header.BackColor = [Drawing.Color]::FromArgb(31, 41, 55); $form.Controls.Add($header)
    $brand = Add-UiLabel $header '使驾   --让您高速驾驶' 24 16 420 28
    $script:WorkflowHeaderBrand = $brand
    $brand.ForeColor = [Drawing.Color]::White; $brand.Font = New-UiFont 12 ([Drawing.FontStyle]::Bold)
    $sessionManager = Add-UiButton $header '会话管理' 684 12 112 34; $sessionManager.Anchor='Top,Right'; $script:SessionManagerButton=$sessionManager
    $runningTasks = Add-UiButton $header '运行中任务' 804 12 112 34; $runningTasks.Anchor='Top,Right'; $script:RunningTasksButton=$runningTasks
    $commonPrompts = Add-UiButton $header '常用提示词' 924 12 112 34; $commonPrompts.Anchor='Top,Right'; $script:CommonPromptsButton=$commonPrompts
    $globalSettings = Add-UiButton $header '全局配置' 1044 12 92 34; $globalSettings.Anchor='Top,Right'
    $workflowAi = Add-UiButton $header '使驾 AI' 1144 12 110 34 'Primary'; $workflowAi.Anchor='Top,Right'

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'; $form.Controls.Add($body)
    $left = New-Object System.Windows.Forms.Panel
    $left.Dock = 'Left'; $left.Width = 320; $left.BackColor = [Drawing.Color]::White; $body.Controls.Add($left)
    Add-UiLabel $left '项目' 18 12 60 24 | Out-Null
    $projectSelectorFrame=New-Object Windows.Forms.Panel;$projectSelectorFrame.Location=New-Object Drawing.Point(18,36);$projectSelectorFrame.Size=New-Object Drawing.Size(204,34);$projectSelectorFrame.Padding=New-Object Windows.Forms.Padding(1);$projectSelectorFrame.BackColor=[Drawing.Color]::FromArgb(203,213,225);$left.Controls.Add($projectSelectorFrame);$script:ProjectSelectorFrame=$projectSelectorFrame
    $script:ProjectSelector = New-Object Windows.Forms.ComboBox; $script:ProjectSelector.Dock='Fill'; $script:ProjectSelector.Margin=New-Object Windows.Forms.Padding(0); $script:ProjectSelector.DropDownStyle='DropDownList'; $script:ProjectSelector.DisplayMember='Name';$script:ProjectSelector.DrawMode='OwnerDrawFixed';$script:ProjectSelector.ItemHeight=30;$script:ProjectSelector.Tag='ProjectSelector';$projectSelectorFrame.Controls.Add($script:ProjectSelector)
     $script:ProjectSelector.Add_DrawItem({param($sender,$e);if($e.Index-lt0-or$e.Index-ge$sender.Items.Count){return};$selected=($e.State-band[Windows.Forms.DrawItemState]::Selected)-eq[Windows.Forms.DrawItemState]::Selected;$background=if($selected){[Drawing.Color]::FromArgb(239,246,255)}else{[Drawing.Color]::White};$foreground=if($selected){[Drawing.Color]::FromArgb(30,64,175)}else{[Drawing.Color]::FromArgb(30,41,59)};$backgroundBrush=New-Object Drawing.SolidBrush($background);$textBrush=New-Object Drawing.SolidBrush($foreground);try{$e.Graphics.FillRectangle($backgroundBrush,$e.Bounds);$item=Get-UiIndexedItemSafe $sender.Items $e.Index;$text=if($null-ne$item){[string]$item.Name}else{''};$textRectangle=New-Object Drawing.RectangleF(($e.Bounds.Left+12),$e.Bounds.Top,($e.Bounds.Width-18),$e.Bounds.Height);$format=New-Object Drawing.StringFormat;$format.LineAlignment=[Drawing.StringAlignment]::Center;$format.Trimming=[Drawing.StringTrimming]::EllipsisCharacter;$e.Graphics.DrawString($text,$sender.Font,$textBrush,$textRectangle,$format);$format.Dispose();if($selected){$accentPen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(59,130,246),3);try{$e.Graphics.DrawLine($accentPen,$e.Bounds.Left+2,$e.Bounds.Top+5,$e.Bounds.Left+2,$e.Bounds.Bottom-5)}finally{$accentPen.Dispose()}}}finally{$backgroundBrush.Dispose();$textBrush.Dispose()}})
    $newProject = Add-UiButton $left '+ 项目' 230 37 72 32 'Primary'
    $script:ProjectInfoLabel = Add-UiLabel $left '' 18 76 284 24 -Muted; $script:ProjectInfoLabel.AutoEllipsis=$true
    $script:ProjectSessionLabel = Add-UiLabel $left '' 18 104 284 24 -Muted; $script:ProjectSessionLabel.AutoEllipsis=$true
    $script:ProjectToolTip=New-Object Windows.Forms.ToolTip
    $editProject = Add-UiButton $left '编辑' 18 136 62 30; $script:ProjectEditButton=$editProject
    $deleteProject = Add-UiButton $left '删除' 86 136 62 30 'Danger'; $script:ProjectDeleteButton=$deleteProject
    $openProject = Add-UiButton $left '打开路径' 154 136 78 30; $script:ProjectOpenButton=$openProject
    $openVSCode = Add-UiButton $left 'VS Code' 238 136 64 30; $script:ProjectVSCodeButton=$openVSCode
    $projectChat = Add-UiButton $left 'Codex 对话' 18 174 136 32 'Primary'; $script:ProjectChatButton=$projectChat
    $projectTerminal = Add-UiButton $left '终端打开' 166 174 136 32; $script:ProjectTerminalButton=$projectTerminal
    $projectDivider=New-Object Windows.Forms.Panel; $projectDivider.Location=New-Object Drawing.Point(18,224); $projectDivider.Size=New-Object Drawing.Size(284,1); $projectDivider.BackColor=[Drawing.Color]::FromArgb(226,232,240); $left.Controls.Add($projectDivider)
    Add-UiLabel $left '工作任务' 18 238 180 28 | Out-Null
    $newTask = Add-UiButton $left '+ 新建任务' 18 270 136 32 'Primary'
    $deleteTask = Add-UiButton $left '删除任务' 166 270 136 32 'Danger'
    $exportConfig = Add-UiButton $left '导出配置' 18 310 136 32
    $importConfig = Add-UiButton $left '导入配置' 166 310 136 32
    $script:WorkflowList = New-Object System.Windows.Forms.ListBox
    $script:WorkflowList.Location = New-Object Drawing.Point(18, 354); $script:WorkflowList.Size = New-Object Drawing.Size(284, 330); $script:WorkflowList.Anchor = 'Top,Bottom,Left,Right'; $script:WorkflowList.Font = New-Object Drawing.Font('Microsoft YaHei UI',10); $script:WorkflowList.BorderStyle = 'None'; $script:WorkflowList.DisplayMember = 'Name';$script:WorkflowList.DrawMode='OwnerDrawFixed';$script:WorkflowList.ItemHeight=42;$script:WorkflowList.IntegralHeight=$false;$script:WorkflowList.Tag='WorkflowTaskList';$script:WorkflowList.BackColor=[Drawing.Color]::White; $left.Controls.Add($script:WorkflowList)
     $script:WorkflowList.Add_DrawItem({param($sender,$e);if($e.Index-lt0-or$e.Index-ge$sender.Items.Count){return};$selected=($e.State-band[Windows.Forms.DrawItemState]::Selected)-eq[Windows.Forms.DrawItemState]::Selected;$background=if($selected){[Drawing.Color]::FromArgb(239,246,255)}elseif(($e.Index%2)-eq1){[Drawing.Color]::FromArgb(248,250,252)}else{[Drawing.Color]::White};$foreground=if($selected){[Drawing.Color]::FromArgb(30,64,175)}else{[Drawing.Color]::FromArgb(30,41,59)};$backgroundBrush=New-Object Drawing.SolidBrush($background);$textBrush=New-Object Drawing.SolidBrush($foreground);try{$e.Graphics.FillRectangle($backgroundBrush,$e.Bounds);$workflow=Get-UiIndexedItemSafe $sender.Items $e.Index;$workflowId=if($null-ne$workflow){[string]$workflow.Id}else{''};$running=-not[string]::IsNullOrWhiteSpace($workflowId)-and$script:RunningJobs.ContainsKey($workflowId);$dotColor=if($running){[Drawing.Color]::FromArgb(37,99,235)}elseif($null-ne$workflow-and[bool]$workflow.Enabled){[Drawing.Color]::FromArgb(16,185,129)}else{[Drawing.Color]::FromArgb(148,163,184)};$dotBrush=New-Object Drawing.SolidBrush($dotColor);try{$e.Graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$e.Graphics.FillEllipse($dotBrush,$e.Bounds.Left+12,$e.Bounds.Top+16,9,9)}finally{$dotBrush.Dispose()};$text=if($null-ne$workflow){[string]$workflow.Name}else{''};$textRectangle=New-Object Drawing.RectangleF(($e.Bounds.Left+30),$e.Bounds.Top,($e.Bounds.Width-40),$e.Bounds.Height);$format=New-Object Drawing.StringFormat;$format.LineAlignment=[Drawing.StringAlignment]::Center;$format.Trimming=[Drawing.StringTrimming]::EllipsisCharacter;$e.Graphics.DrawString($text,$sender.Font,$textBrush,$textRectangle,$format);$format.Dispose();$linePen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(241,245,249));try{$e.Graphics.DrawLine($linePen,$e.Bounds.Left+10,$e.Bounds.Bottom-1,$e.Bounds.Right-10,$e.Bounds.Bottom-1)}finally{$linePen.Dispose()}}finally{$backgroundBrush.Dispose();$textBrush.Dispose()}})
    $script:WorkflowListContextMenu = New-Object Windows.Forms.ContextMenuStrip
    $workflowRunItem = $script:WorkflowListContextMenu.Items.Add('执行一次')
    $workflowStopItem = $script:WorkflowListContextMenu.Items.Add('停止')
    $workflowRestartItem = $script:WorkflowListContextMenu.Items.Add('重新执行')
    [void]$script:WorkflowListContextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $workflowMoveUpItem = $script:WorkflowListContextMenu.Items.Add('上移')
    $workflowMoveDownItem = $script:WorkflowListContextMenu.Items.Add('下移')
    [void]$script:WorkflowListContextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $workflowCopyItem = $script:WorkflowListContextMenu.Items.Add('复制工作任务')
    $workflowPasteItem = $script:WorkflowListContextMenu.Items.Add('粘贴到当前项目')
    [void]$script:WorkflowListContextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $workflowDeleteItem = $script:WorkflowListContextMenu.Items.Add('删除工作任务')
    $script:WorkflowListContextMenu.Add_Opening({
        $selectedWorkflow=if($script:WorkflowList.SelectedIndex-ge0){$script:WorkflowList.SelectedItem}else{$null}
        $selectedWorkflowId=if($null-ne$selectedWorkflow){[string]$selectedWorkflow.Id}else{''}
        $isRunning=-not[string]::IsNullOrWhiteSpace($selectedWorkflowId)-and$script:RunningJobs.ContainsKey($selectedWorkflowId)
        $workflowRunItem.Enabled=$null-ne$selectedWorkflow-and-not$isRunning
        $workflowStopItem.Enabled=$isRunning-and-not[bool]$script:RunningJobs[$selectedWorkflowId].StopRequested
        $workflowRestartItem.Enabled=$null-ne$selectedWorkflow
        $moveState=Get-WorkflowMoveState
        $workflowMoveUpItem.Enabled=[bool]$moveState.CanMoveUp
        $workflowMoveDownItem.Enabled=[bool]$moveState.CanMoveDown
        $workflowCopyItem.Enabled=$script:WorkflowList.SelectedIndex-ge0
        $workflowPasteItem.Enabled=-not[string]::IsNullOrWhiteSpace($script:CopiedWorkflowJson)
        $workflowDeleteItem.Enabled=$null-ne$selectedWorkflow-and-not$isRunning-and@($script:Workflows).Count-gt1
    })
    $workflowRunItem.Add_Click({if($script:WorkflowList.SelectedIndex-ge0){Start-WorkflowJob $script:WorkflowList.SelectedItem -Manual}})
    $workflowStopItem.Add_Click({
        if($script:WorkflowList.SelectedIndex-lt0){return}
        $workflowId=[string]$script:WorkflowList.SelectedItem.Id;if(-not$script:RunningJobs.ContainsKey($workflowId)){return}
        [void](Stop-WorkflowJob $workflowId)
    })
    $workflowRestartItem.Add_Click({
        if($script:WorkflowList.SelectedIndex-lt0){return}
        $workflowId=[string]$script:WorkflowList.SelectedItem.Id
        if($script:RunningJobs.ContainsKey($workflowId)){
            $answer=[Windows.Forms.MessageBox]::Show(('任务正在运行。重新执行将先终止“'+[string]$script:WorkflowList.SelectedItem.Name+'”及其子进程，然后启动一次新执行。'),'重新执行',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
            if($answer-ne[Windows.Forms.DialogResult]::Yes){return}
        }
        [void](Restart-WorkflowJob $workflowId)
    })
    $workflowMoveUpItem.Add_Click({[void](Move-SelectedWorkflow -Direction -1)})
    $workflowMoveDownItem.Add_Click({[void](Move-SelectedWorkflow -Direction 1)})
    $workflowCopyItem.Add_Click({[void](Copy-SelectedWorkflow)})
    $workflowPasteItem.Add_Click({[void](Paste-CopiedWorkflow)})
    $workflowDeleteItem.Add_Click({[void](Remove-SelectedWorkflowTask)})
    $script:WorkflowList.ContextMenuStrip=$script:WorkflowListContextMenu

    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Fill'; $right.BackColor = [Drawing.Color]::FromArgb(248, 250, 252); $body.Controls.Add($right); $script:CommonPromptsHost=$right
    $body.Controls.SetChildIndex($left, 1); $body.Controls.SetChildIndex($right, 0)
    $settings = New-Object System.Windows.Forms.TableLayoutPanel
    $settings.Dock = 'Top'; $settings.Height = 112; $settings.BackColor = [Drawing.Color]::White; $settings.ColumnCount = 1; $settings.RowCount = 2; $settings.Margin = New-Object Windows.Forms.Padding(0); $settings.Padding = New-Object Windows.Forms.Padding(0)
    [void]$settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$settings.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 54)))
    [void]$settings.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    $right.Controls.Add($settings)
    $script:WorkflowSettingsPanel = $settings
    $workflowInfoPanel=New-Object Windows.Forms.Panel; $workflowInfoPanel.Dock='Fill'; $workflowInfoPanel.Margin=New-Object Windows.Forms.Padding(0); $workflowInfoPanel.BackColor=[Drawing.Color]::White; $settings.Controls.Add($workflowInfoPanel,0,0)
    Add-UiLabel $workflowInfoPanel '任务名称' 12 10 60 24 -Muted | Out-Null
    $workflowNameFrame=New-Object Windows.Forms.Panel;$workflowNameFrame.Location=New-Object Drawing.Point(76,5);$workflowNameFrame.Size=New-Object Drawing.Size(210,36);$workflowNameFrame.Padding=New-Object Windows.Forms.Padding(1);$workflowNameFrame.BackColor=[Drawing.Color]::FromArgb(203,213,225);$workflowInfoPanel.Controls.Add($workflowNameFrame);$script:WorkflowNameFrame=$workflowNameFrame
    $workflowNameSurface=New-Object Windows.Forms.Panel;$workflowNameSurface.Dock='Fill';$workflowNameSurface.Padding=New-Object Windows.Forms.Padding(10,5,8,4);$workflowNameSurface.BackColor=[Drawing.Color]::White;$workflowNameFrame.Controls.Add($workflowNameSurface)
    $script:WorkflowNameBox = New-Object System.Windows.Forms.TextBox; $script:WorkflowNameBox.Dock='Fill';$script:WorkflowNameBox.Margin=New-Object Windows.Forms.Padding(0);$script:WorkflowNameBox.BorderStyle='None';$script:WorkflowNameBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',10.5);$script:WorkflowNameBox.Tag='WorkflowNameInput';$workflowNameSurface.Controls.Add($script:WorkflowNameBox)
    $script:WorkflowNameBox.Add_Enter({if($null-ne$script:WorkflowNameFrame){$script:WorkflowNameFrame.BackColor=[Drawing.Color]::FromArgb(59,130,246)}});$script:WorkflowNameBox.Add_Leave({if($null-ne$script:WorkflowNameFrame){$script:WorkflowNameFrame.BackColor=[Drawing.Color]::FromArgb(203,213,225)}})
    $script:WorkflowEnabled = New-Object System.Windows.Forms.CheckBox; $script:WorkflowEnabled.Location = New-Object Drawing.Point(296, 10); $script:WorkflowEnabled.Size = New-Object Drawing.Size(60, 24); $script:WorkflowEnabled.Text = '启用'; $script:WorkflowEnabled.Font = New-UiFont 9; $workflowInfoPanel.Controls.Add($script:WorkflowEnabled)
    $scheduleButton=Add-UiButton $workflowInfoPanel '定时配置' 362 6 90 32
    $script:ScheduleButton=$scheduleButton
    $script:NextRunLabel = Add-UiLabel $workflowInfoPanel '' 460 11 200 24 -Muted; $script:NextRunLabel.AutoEllipsis=$true; $script:NextRunLabel.Anchor='Top,Left,Right'
    $workflowActions=New-Object Windows.Forms.FlowLayoutPanel; $workflowActions.Dock='Right'; $workflowActions.Width=286; $workflowActions.FlowDirection='LeftToRight'; $workflowActions.WrapContents=$false; $workflowActions.Padding=New-Object Windows.Forms.Padding(0,5,0,0); $workflowActions.BackColor=[Drawing.Color]::White; $workflowInfoPanel.Controls.Add($workflowActions)
    $script:WorkflowActionsPanel=$workflowActions
    $saveWorkflow = Add-UiButton $workflowActions '保存' 0 0 72 34
    $runWorkflow = Add-UiButton $workflowActions '立即运行' 0 0 92 34 'Primary'
    $deleteNode = Add-UiButton $workflowActions '删除选中' 0 0 92 34 'Danger'
    foreach($button in @($saveWorkflow,$runWorkflow,$deleteNode)){$button.Margin=New-Object Windows.Forms.Padding(0,0,6,0)}
    $nodeBar=New-Object Windows.Forms.FlowLayoutPanel; $nodeBar.Dock='Fill'; $nodeBar.FlowDirection='LeftToRight'; $nodeBar.WrapContents=$false; $nodeBar.AutoScroll=$true; $nodeBar.Margin=New-Object Windows.Forms.Padding(0); $nodeBar.Padding=New-Object Windows.Forms.Padding(8,7,8,3); $nodeBar.BackColor=[Drawing.Color]::FromArgb(248,250,252); $settings.Controls.Add($nodeBar,0,1)
    $script:CommandPanel=$nodeBar
    $addStart = Add-UiButton $nodeBar '+ 开始' 0 0 64 32 'Node'; $addEnd = Add-UiButton $nodeBar '+ 结束' 0 0 64 32 'Node'; $addHttp = Add-UiButton $nodeBar '+ 网络请求' 0 0 92 32 'Node'; $addRead = Add-UiButton $nodeBar '+ 变量读取' 0 0 92 32 'Node'; $addWrite = Add-UiButton $nodeBar '+ 变量写入' 0 0 92 32 'Node'; $addVariable = Add-UiButton $nodeBar '+ 赋值' 0 0 72 32 'Node'; $addCmd = Add-UiButton $nodeBar '+ CMD' 0 0 70 32 'Node'; $addPython = Add-UiButton $nodeBar '+ Python' 0 0 82 32 'Node'; $addIf = Add-UiButton $nodeBar '+ 判断' 0 0 72 32 'Node'; $addForEach = Add-UiButton $nodeBar '+ 循环' 0 0 72 32 'Node'; $addLoopEnd = Add-UiButton $nodeBar '+ 循环结束' 0 0 92 32 'Node'; $addDelay = Add-UiButton $nodeBar '+ 延时' 0 0 72 32 'Node'; $addBalloon = Add-UiButton $nodeBar '+ 气泡提醒' 0 0 98 32 'Node'; $addCodex = Add-UiButton $nodeBar '+ 调用 Codex' 0 0 106 32 'Node'
    foreach($button in @($addStart,$addEnd,$addHttp,$addRead,$addWrite,$addVariable,$addCmd,$addPython,$addIf,$addForEach,$addLoopEnd,$addDelay,$addBalloon,$addCodex)){$button.Margin=New-Object Windows.Forms.Padding(0,0,6,0)}
    $scheduleStateHost=New-Object Windows.Forms.Panel; $scheduleStateHost.Visible=$false; $scheduleStateHost.Size=New-Object Drawing.Size(1,1); $workflowInfoPanel.Controls.Add($scheduleStateHost)
    $script:ScheduleModeBox = New-Object Windows.Forms.ComboBox; $script:ScheduleModeBox.DisplayMember='Text';$script:ScheduleModeBox.ValueMember='Value';[void]$script:ScheduleModeBox.Items.Add([pscustomobject]@{Text='循环执行';Value='Loop'});[void]$script:ScheduleModeBox.Items.Add([pscustomobject]@{Text='执行一次';Value='Once'});$scheduleStateHost.Controls.Add($script:ScheduleModeBox)
    $script:ScheduleKindBox = New-Object Windows.Forms.ComboBox; $script:ScheduleKindBox.DisplayMember='Text';$script:ScheduleKindBox.ValueMember='Value';$scheduleStateHost.Controls.Add($script:ScheduleKindBox)
    $script:IntervalLabel=New-Object Windows.Forms.Label;$script:IntervalBox=New-Object Windows.Forms.NumericUpDown;$script:IntervalBox.Minimum=1;$script:IntervalBox.Maximum=10080;$script:IntervalBox.Value=60;$script:ScheduleTimeLabel=New-Object Windows.Forms.Label;$script:ScheduleTimeBox=New-Object Windows.Forms.TextBox;$script:ScheduleTimeBox.Text='09:00:00';$script:ScheduleWeekdaysLabel=New-Object Windows.Forms.Label;$script:ScheduleWeekdaysBox=New-Object Windows.Forms.TextBox;$script:ScheduleWeekdaysBox.Text='1';$script:ScheduleDayLabel=New-Object Windows.Forms.Label;$script:ScheduleDayBox=New-Object Windows.Forms.NumericUpDown;$script:ScheduleDayBox.Minimum=1;$script:ScheduleDayBox.Maximum=31;$script:ScheduleDayBox.Value=1
    foreach($control in @($script:IntervalLabel,$script:IntervalBox,$script:ScheduleTimeLabel,$script:ScheduleTimeBox,$script:ScheduleWeekdaysLabel,$script:ScheduleWeekdaysBox,$script:ScheduleDayLabel,$script:ScheduleDayBox)){$scheduleStateHost.Controls.Add($control)}

    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = 'Bottom'; $logPanel.Height = 160; $logPanel.BackColor = [Drawing.Color]::White; $right.Controls.Add($logPanel)
    $script:WorkflowLogPanel = $logPanel
    Add-UiLabel $logPanel '执行日志' 12 8 120 22 | Out-Null
    $script:LogBox = New-Object System.Windows.Forms.RichTextBox
    $script:LogBox.Location = New-Object Drawing.Point(12, 32); $script:LogBox.Size = New-Object Drawing.Size(940, 118); $script:LogBox.Anchor = 'Top,Bottom,Left,Right'; $script:LogBox.ReadOnly = $true; $script:LogBox.BackColor = [Drawing.Color]::FromArgb(249, 250, 251); $script:LogBox.BorderStyle = 'None'; $script:LogBox.Font = New-UiFont 8.5; $logPanel.Controls.Add($script:LogBox)
    $script:GlobalLogVisibleLineCount=0
    if (Test-Path -LiteralPath $script:LogPath) { try {$logTail=@([IO.File]::ReadLines($script:LogPath,[Text.Encoding]::UTF8)|Select-Object -Last 1200);$script:GlobalLogVisibleLineCount=$logTail.Count;if($logTail.Count-gt0){$script:LogBox.Text=($logTail-join[Environment]::NewLine)+[Environment]::NewLine}} catch { } }

    $script:Canvas = New-Object WorkflowCanvasPanel
    $script:Canvas.Dock = 'Fill'; $script:Canvas.AutoScroll = $true; $script:Canvas.AutoScrollMinSize = Get-DefaultCanvasExtent; $right.Controls.Add($script:Canvas)
    $right.Controls.SetChildIndex($settings, 2); $right.Controls.SetChildIndex($logPanel, 1); $right.Controls.SetChildIndex($script:Canvas, 0)
    $script:CanvasContextMenu = New-Object Windows.Forms.ContextMenuStrip
    $canvasEditItem = $script:CanvasContextMenu.Items.Add('编辑节点')
    $canvasCopyItem = $script:CanvasContextMenu.Items.Add('复制节点')
    $canvasPasteItem = $script:CanvasContextMenu.Items.Add('粘贴节点')
    [void]$script:CanvasContextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $canvasDeleteItem = $script:CanvasContextMenu.Items.Add('删除选中')
    $script:CanvasContextMenu.Add_Opening({
        $hasNode=$null-ne$script:SelectedNode; $hasEdge=$null-ne$script:SelectedEdge
        $canvasEditItem.Visible=$hasNode
        $canvasCopyItem.Visible=$hasNode
        $canvasCopyItem.Enabled=$hasNode-and([string]$script:SelectedNode.Type-notin@('Start','End'))
        $canvasPasteItem.Enabled=$null-ne$script:CurrentWorkflow-and-not[string]::IsNullOrWhiteSpace($script:CopiedCanvasNodeJson)
        $canvasDeleteItem.Enabled=$hasNode-or$hasEdge
        $canvasDeleteItem.Text=if($hasEdge){'删除连线'}else{'删除选中'}
    })
    $canvasEditItem.Add_Click({if($null-ne$script:SelectedNode-and(Show-NodeEditor $script:SelectedNode)-eq'OK'){$script:Canvas.Invalidate()}})
    $canvasCopyItem.Add_Click({[void](Copy-SelectedCanvasNode)})
    $canvasPasteItem.Add_Click({[void](Paste-CopiedCanvasNode $script:CanvasContextPoint)})
    $canvasDeleteItem.Add_Click({Remove-SelectedCanvasItem})

    $script:CodexConversationPanel = New-Object Windows.Forms.Panel; $script:CodexConversationPanel.Dock='Fill'; $script:CodexConversationPanel.Padding=New-Object Windows.Forms.Padding(18); $script:CodexConversationPanel.BackColor=[Drawing.Color]::FromArgb(241,245,249); $script:CodexConversationPanel.Visible=$false; $right.Controls.Add($script:CodexConversationPanel)
    $conversationSplit=New-Object Windows.Forms.SplitContainer; $conversationSplit.Dock='Fill'; $conversationSplit.Margin=New-Object Windows.Forms.Padding(0); $conversationSplit.Orientation=[Windows.Forms.Orientation]::Vertical; $conversationSplit.FixedPanel=[Windows.Forms.FixedPanel]::Panel2; $conversationSplit.SplitterWidth=6; $conversationSplit.BackColor=[Drawing.Color]::FromArgb(226,232,240); $conversationSplit.Panel1.BackColor=[Drawing.Color]::FromArgb(241,245,249); $conversationSplit.Panel2.BackColor=[Drawing.Color]::FromArgb(241,245,249); $conversationSplit.Panel2.Padding=New-Object Windows.Forms.Padding(10,0,0,0); $script:CodexConversationPanel.Controls.Add($conversationSplit); $script:CodexConversationSplit=$conversationSplit
    $conversationLayout=New-Object Windows.Forms.TableLayoutPanel; $conversationLayout.Dock='Fill'; $conversationLayout.Margin=New-Object Windows.Forms.Padding(0); $conversationLayout.Padding=New-Object Windows.Forms.Padding(0); $conversationLayout.ColumnCount=1; $conversationLayout.RowCount=3; $conversationLayout.BackColor=[Drawing.Color]::FromArgb(241,245,249); [void]$conversationLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))); [void]$conversationLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,88))); [void]$conversationLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))); [void]$conversationLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,124))); $conversationSplit.Panel1.Controls.Add($conversationLayout); $script:CodexConversationLayout=$conversationLayout
    $conversationHeader=New-Object Windows.Forms.Panel; $conversationHeader.Dock='Fill'; $conversationHeader.Margin=New-Object Windows.Forms.Padding(0); $conversationHeader.BackColor=[Drawing.Color]::FromArgb(241,245,249); $conversationLayout.Controls.Add($conversationHeader,0,0); $script:CodexConversationHeader=$conversationHeader
    $script:CodexConversationTitle=Add-UiLabel $conversationHeader 'Codex 会话' 20 11 480 34; $script:CodexConversationTitle.ForeColor=[Drawing.Color]::FromArgb(15,23,42); $script:CodexConversationTitle.BackColor=[Drawing.Color]::Transparent; $script:CodexConversationTitle.Font=New-UiFont 12 ([Drawing.FontStyle]::Bold); $script:CodexConversationTitle.AutoEllipsis=$true; $script:CodexConversationTitle.TextAlign=[Drawing.ContentAlignment]::MiddleLeft
    $script:CodexConversationMeta=Add-UiLabel $conversationHeader '' 20 45 560 38 -Muted; $script:CodexConversationMeta.Visible=$false; $script:CodexConversationMeta.TabStop=$false
    $script:CodexConversationSessionSelector=New-Object Windows.Forms.ComboBox;$script:CodexConversationSessionSelector.Location=New-Object Drawing.Point(20,47);$script:CodexConversationSessionSelector.Size=New-Object Drawing.Size(320,30);$script:CodexConversationSessionSelector.DropDownStyle='DropDownList';$script:CodexConversationSessionSelector.DisplayMember='DisplayText';$script:CodexConversationSessionSelector.DrawMode=[Windows.Forms.DrawMode]::OwnerDrawFixed;$script:CodexConversationSessionSelector.ItemHeight=28;$script:CodexConversationSessionSelector.Tag='CodexSessionSelector';$script:CodexConversationSessionSelector.Font=New-UiFont 9.5;$script:CodexConversationSessionSelector.IntegralHeight=$false;$script:CodexConversationSessionSelector.DropDownHeight=280;$script:CodexConversationSessionSelector.DropDownWidth=340;$script:CodexConversationSessionSelector.Visible=$false;$conversationHeader.Controls.Add($script:CodexConversationSessionSelector)
    $script:CodexConversationSessionSelector.Add_DrawItem({param($sender,$e);$index=[int]$e.Index;if($index-lt0-or$index-ge$sender.Items.Count){return};$selected=($e.State-band[Windows.Forms.DrawItemState]::Selected)-eq[Windows.Forms.DrawItemState]::Selected;$background=if($selected){[Drawing.Color]::FromArgb(239,246,255)}else{[Drawing.Color]::White};$foreground=if($selected){[Drawing.Color]::FromArgb(30,64,175)}else{[Drawing.Color]::FromArgb(30,41,59)};$backgroundBrush=New-Object Drawing.SolidBrush($background);$textBrush=New-Object Drawing.SolidBrush($foreground);try{$e.Graphics.FillRectangle($backgroundBrush,$e.Bounds);$item=Get-UiIndexedItemSafe $sender.Items $index;$text=if($null-ne$item){[string](Get-UiConfigValue $item 'DisplayText' '')}else{''};$textRectangle=New-Object Drawing.RectangleF(($e.Bounds.Left+10),$e.Bounds.Top,([Math]::Max(1,$e.Bounds.Width-18)),$e.Bounds.Height);$format=New-Object Drawing.StringFormat;$format.LineAlignment=[Drawing.StringAlignment]::Center;$format.Trimming=[Drawing.StringTrimming]::EllipsisCharacter;$e.Graphics.DrawString($text,$sender.Font,$textBrush,$textRectangle,$format);$format.Dispose();if($selected){$accentPen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(59,130,246),3);try{$e.Graphics.DrawLine($accentPen,$e.Bounds.Left+2,$e.Bounds.Top+5,$e.Bounds.Left+2,$e.Bounds.Bottom-5)}finally{$accentPen.Dispose()}}}finally{$backgroundBrush.Dispose();$textBrush.Dispose()}})
    $script:CodexConversationSearchLabel=Add-UiLabel $conversationHeader '查找' 390 51 42 24; $script:CodexConversationSearchLabel.Font=New-UiFont 9.5; $script:CodexConversationSearchLabel.ForeColor=[Drawing.Color]::FromArgb(71,85,105); $script:CodexConversationSearchLabel.TextAlign=[Drawing.ContentAlignment]::MiddleLeft; $script:CodexConversationSearchLabel.Anchor='Top,Right'
    $script:CodexConversationSearchFrame=New-Object Windows.Forms.Panel; $script:CodexConversationSearchFrame.Location=New-Object Drawing.Point(430,49); $script:CodexConversationSearchFrame.Size=New-Object Drawing.Size(154,28); $script:CodexConversationSearchFrame.Padding=New-Object Windows.Forms.Padding(1); $script:CodexConversationSearchFrame.BackColor=[Drawing.Color]::FromArgb(203,213,225); $script:CodexConversationSearchFrame.Anchor='Top,Right'; $conversationHeader.Controls.Add($script:CodexConversationSearchFrame)
    $script:CodexConversationSearchBox=New-Object Windows.Forms.TextBox; $script:CodexConversationSearchBox.Dock='Fill'; $script:CodexConversationSearchBox.AutoSize=$false; $script:CodexConversationSearchBox.BorderStyle='None'; $script:CodexConversationSearchBox.BackColor=[Drawing.Color]::White; $script:CodexConversationSearchBox.ForeColor=[Drawing.Color]::FromArgb(15,23,42); $script:CodexConversationSearchBox.Font=New-UiFont 9.5; $script:CodexConversationSearchBox.ShortcutsEnabled=$true; $script:CodexConversationSearchBox.Tag='CodexConversationSearch'; $script:CodexConversationSearchFrame.Controls.Add($script:CodexConversationSearchBox)
    $script:CodexConversationSearchBox.Add_HandleCreated({param($sender,$e);try{[WorkflowNativeMethods]::ApplyTextMargins($sender,6)}catch{}})
    $script:CodexConversationStatus=Add-UiLabel $conversationHeader '等待进入会话' 600 53 180 24; $script:CodexConversationStatus.Anchor='Top,Right'; $script:CodexConversationStatus.TextAlign='MiddleRight'
    $conversationBack=Add-UiButton $conversationHeader '返回工作流' 788 13 106 32; $conversationBack.Anchor='Top,Right'; $script:CodexConversationBackButton=$conversationBack
    $conversationReload=Add-UiButton $conversationHeader '刷新历史' 676 13 102 32; $conversationReload.Anchor='Top,Right'; $script:CodexConversationReloadButton=$conversationReload
    $conversationStop=Add-UiButton $conversationHeader '停止会话' 584 13 84 32 'Danger'; $conversationStop.Anchor='Top,Right'; $conversationStop.Enabled=$false; $script:CodexConversationStopButton=$conversationStop
    $conversationPreviousUser=Add-UiButton $conversationHeader '↑' 630 13 38 32; $conversationPreviousUser.Anchor='Top,Right'; $script:CodexConversationPreviousUserButton=$conversationPreviousUser
    $conversationToolTip=New-Object Windows.Forms.ToolTip;$conversationToolTip.SetToolTip($conversationPreviousUser,'定位到上一个我发出的消息');$conversationToolTip.SetToolTip($script:CodexConversationSearchBox,'输入文本后按回车，从下到上逐个定位；Esc 清空')
    $conversationFiles=Add-UiButton $conversationHeader '收起文件' 700 13 84 32; $conversationFiles.Anchor='Top,Right'; $script:CodexConversationFileTreeToggleButton=$conversationFiles; $conversationToolTip.SetToolTip($conversationFiles,'显示或收起当前工作目录文件树')
    $conversationTerminal=Add-UiButton $conversationHeader '终端打开' 900 13 100 32; $conversationTerminal.Anchor='Top,Right'; $script:CodexConversationTerminalButton=$conversationTerminal
    foreach($headerButton in @($conversationStop,$conversationReload,$conversationFiles,$conversationBack,$conversationTerminal)){$headerButton.Width=[Math]::Max($headerButton.Width,$headerButton.PreferredSize.Width+18)}
    $palette=Get-CodexConversationPalette
    $outputHost=New-Object Windows.Forms.Panel; $outputHost.Dock='Fill'; $outputHost.Margin=New-Object Windows.Forms.Padding(0,8,0,8); $outputHost.Padding=New-Object Windows.Forms.Padding(4); $outputHost.BackColor=$palette.Surface; $conversationLayout.Controls.Add($outputHost,0,1); $script:CodexConversationOutputHost=$outputHost
    $script:CodexConversationOutput=New-Object WorkflowBufferedFlowLayoutPanel; $script:CodexConversationOutput.Dock='Fill'; $script:CodexConversationOutput.Margin=New-Object Windows.Forms.Padding(0); $script:CodexConversationOutput.Padding=New-Object Windows.Forms.Padding(12,10,12,10); $script:CodexConversationOutput.BackColor=$palette.Surface; $script:CodexConversationOutput.AutoScroll=$true; $outputHost.Controls.Add($script:CodexConversationOutput)
    $script:CodexConversationOutput.Add_Resize({[void](Resize-CodexConversationBubbles)})
    $conversationToolTip.SetToolTip($script:CodexConversationOutput,'按住 Ctrl 并单击链接即可打开')
    $script:CodexConversationComposerRowStyle=$conversationLayout.RowStyles[2]
    $conversationComposer=New-Object Windows.Forms.Panel; $conversationComposer.Dock='Fill'; $conversationComposer.Margin=New-Object Windows.Forms.Padding(0); $conversationComposer.Padding=New-Object Windows.Forms.Padding(18,20,18,14); $conversationComposer.BackColor=[Drawing.Color]::White; $conversationLayout.Controls.Add($conversationComposer,0,2); $script:CodexConversationComposer=$conversationComposer
    $conversationComposerLayout=New-Object Windows.Forms.TableLayoutPanel; $conversationComposerLayout.Dock='Fill'; $conversationComposerLayout.Margin=New-Object Windows.Forms.Padding(0); $conversationComposerLayout.Padding=New-Object Windows.Forms.Padding(0); $conversationComposerLayout.ColumnCount=2; $conversationComposerLayout.RowCount=1; $conversationComposerLayout.BackColor=$palette.Surface; [void]$conversationComposerLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))); [void]$conversationComposerLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,156))); [void]$conversationComposerLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))); $conversationComposer.Controls.Add($conversationComposerLayout);$script:CodexConversationComposerLayout=$conversationComposerLayout
    $conversationInputFrame=New-Object Windows.Forms.Panel; $conversationInputFrame.Dock='Fill'; $conversationInputFrame.Margin=New-Object Windows.Forms.Padding(0,0,12,0); $conversationInputFrame.Padding=New-Object Windows.Forms.Padding(1); $conversationInputFrame.BackColor=[Drawing.Color]::FromArgb(203,213,225); $conversationComposerLayout.Controls.Add($conversationInputFrame,0,0); $script:CodexConversationInputFrame=$conversationInputFrame
    $conversationInputSurface=New-Object Windows.Forms.TableLayoutPanel; $conversationInputSurface.Dock='Fill'; $conversationInputSurface.Margin=New-Object Windows.Forms.Padding(0); $conversationInputSurface.Padding=New-Object Windows.Forms.Padding(12,9,10,8); $conversationInputSurface.BackColor=$palette.InputBackground; $conversationInputSurface.ColumnCount=1; $conversationInputSurface.RowCount=2; [void]$conversationInputSurface.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))); [void]$conversationInputSurface.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))); [void]$conversationInputSurface.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,0))); $conversationInputFrame.Controls.Add($conversationInputSurface);$script:CodexConversationInputSurface=$conversationInputSurface
    $script:CodexConversationInput=New-Object Windows.Forms.TextBox; $script:CodexConversationInput.Dock='Fill'; $script:CodexConversationInput.Margin=New-Object Windows.Forms.Padding(0); $script:CodexConversationInput.Multiline=$true; $script:CodexConversationInput.ScrollBars='Vertical'; $script:CodexConversationInput.AcceptsReturn=$true; $script:CodexConversationInput.BackColor=$palette.InputBackground; $script:CodexConversationInput.ForeColor=$palette.InputText; $script:CodexConversationInput.BorderStyle='None'; $script:CodexConversationInput.Font=New-Object Drawing.Font('Microsoft YaHei UI',10.5); $script:CodexConversationInput.Tag='CodexConversationInput'; $conversationInputSurface.Controls.Add($script:CodexConversationInput,0,0)
    $script:CodexConversationAttachmentPreview=New-Object Windows.Forms.FlowLayoutPanel; $script:CodexConversationAttachmentPreview.Dock='Fill'; $script:CodexConversationAttachmentPreview.Margin=New-Object Windows.Forms.Padding(0); $script:CodexConversationAttachmentPreview.Padding=New-Object Windows.Forms.Padding(0); $script:CodexConversationAttachmentPreview.FlowDirection=[Windows.Forms.FlowDirection]::LeftToRight; $script:CodexConversationAttachmentPreview.WrapContents=$false; $script:CodexConversationAttachmentPreview.AutoScroll=$true; $script:CodexConversationAttachmentPreview.BackColor=$palette.InputBackground; $script:CodexConversationAttachmentPreview.Visible=$false; $conversationInputSurface.Controls.Add($script:CodexConversationAttachmentPreview,0,1)
    $script:CodexConversationInput.Add_Enter({if($null-ne$script:CodexConversationInputFrame){$script:CodexConversationInputFrame.BackColor=[Drawing.Color]::FromArgb(59,130,246)}})
    $script:CodexConversationInput.Add_Leave({if($null-ne$script:CodexConversationInputFrame){$script:CodexConversationInputFrame.BackColor=[Windows.Forms.ControlPaint]::Dark((Get-CodexConversationPalette).Surface)}})
    $conversationActions=New-Object Windows.Forms.Panel; $conversationActions.Dock='Fill'; $conversationActions.Margin=New-Object Windows.Forms.Padding(0); $conversationActions.BackColor=$palette.Surface; $conversationComposerLayout.Controls.Add($conversationActions,1,0);$script:CodexConversationActions=$conversationActions
    $script:CodexConversationSend=Add-UiButton $conversationActions '发送' 0 0 156 38 'Primary'; $script:CodexConversationSend.Anchor='Top,Left,Right'
    $script:CodexConversationComposerExpandButton=Add-UiButton $conversationActions '展开' 94 0 62 38; $script:CodexConversationComposerExpandButton.Anchor='Top,Right'
    $script:CodexConversationAttachButton=Add-UiButton $conversationActions '粘贴图片' 0 46 74 28; $script:CodexConversationAttachButton.Anchor='Top,Left'
    $script:CodexConversationClearAttachmentsButton=Add-UiButton $conversationActions '清空图片' 82 46 74 28; $script:CodexConversationClearAttachmentsButton.Anchor='Top,Right'; $script:CodexConversationClearAttachmentsButton.Enabled=$false
    $conversationGrip=New-Object Windows.Forms.Panel; $conversationGrip.Size=New-Object Drawing.Size(76,6); $conversationGrip.Location=New-Object Drawing.Point(20,5); $conversationGrip.Anchor='Top'; $conversationGrip.Cursor=[Windows.Forms.Cursors]::SizeNS; $conversationGrip.BackColor=[Drawing.Color]::FromArgb(148,163,184); $conversationGrip.Tag='ConversationComposerResizeGrip'; $conversationComposer.Controls.Add($conversationGrip); $conversationGrip.BringToFront(); $script:CodexConversationComposerResizeGrip=$conversationGrip
    $conversationToolTip.SetToolTip($conversationGrip,'向上拖动放大输入区，向下拖动收起；双击可展开或还原')
    $conversationToolTip.SetToolTip($script:CodexConversationComposerExpandButton,'展开或还原对话输入区')
    $conversationToolTip.SetToolTip($script:CodexConversationAttachButton,'粘贴剪切板中的图片')
    $conversationToolTip.SetToolTip($script:CodexConversationClearAttachmentsButton,'清空待发送的图片')
    $layoutConversationComposer={
        Sync-CodexConversationComposerChildHeight
        $buttonPadding=[Math]::Max((ConvertTo-WorkflowDpiPixels 8 6),[int]($script:CodexConversationSend.Font.Height*0.55))
        $actionGap=[Math]::Max((ConvertTo-WorkflowDpiPixels 6 5),[int]($script:CodexConversationSend.Height*0.14))
        $attachTextWidth=[Windows.Forms.TextRenderer]::MeasureText([string]$script:CodexConversationAttachButton.Text,$script:CodexConversationAttachButton.Font).Width
        $clearTextWidth=[Windows.Forms.TextRenderer]::MeasureText([string]$script:CodexConversationClearAttachmentsButton.Text,$script:CodexConversationClearAttachmentsButton.Font).Width
        $expandTextWidth=[Windows.Forms.TextRenderer]::MeasureText([string]$script:CodexConversationComposerExpandButton.Text,$script:CodexConversationComposerExpandButton.Font).Width
        $sendTextWidth=[Windows.Forms.TextRenderer]::MeasureText([string]$script:CodexConversationSend.Text,$script:CodexConversationSend.Font).Width
        $currentAttachWidth=[Math]::Max((ConvertTo-WorkflowDpiPixels 70 58),$attachTextWidth+$buttonPadding)
        $currentClearWidth=[Math]::Max((ConvertTo-WorkflowDpiPixels 70 58),$clearTextWidth+$buttonPadding)
        $currentExpandWidth=[Math]::Max((ConvertTo-WorkflowDpiPixels 58 50),$expandTextWidth+$buttonPadding)
        $currentSendMinimumWidth=[Math]::Max((ConvertTo-WorkflowDpiPixels 60 52),$sendTextWidth+$buttonPadding)
        $requiredActionsWidth=[Math]::Max(($currentSendMinimumWidth+$currentExpandWidth+$actionGap),($currentAttachWidth+$currentClearWidth+$actionGap))
        $availableComposerWidth=[Math]::Max(1,$conversationComposerLayout.ClientSize.Width)
        $singleButtonMinimum=[Math]::Max($currentSendMinimumWidth,[Math]::Max($currentExpandWidth,[Math]::Max($currentAttachWidth,$currentClearWidth)))
        $compactActionsLimit=[Math]::Max($singleButtonMinimum,(ConvertTo-WorkflowDpiPixels 158 132))
        $ratioActionsLimit=[Math]::Max($singleButtonMinimum,[int][Math]::Floor($availableComposerWidth*0.28))
        $inputReservedWidth=[Math]::Max((ConvertTo-WorkflowDpiPixels 280 220),[int][Math]::Floor($availableComposerWidth*0.72))
        $inputProtectedActionsLimit=[Math]::Max($singleButtonMinimum,$availableComposerWidth-$inputReservedWidth)
        $maximumActionsWidth=[Math]::Min($compactActionsLimit,[Math]::Min($ratioActionsLimit,$inputProtectedActionsLimit))
        $actionsWidth=[Math]::Max(1,[Math]::Min($requiredActionsWidth,$maximumActionsWidth))
        if([Math]::Abs($conversationComposerLayout.ColumnStyles[1].Width-$actionsWidth)-gt1){$conversationComposerLayout.ColumnStyles[1].Width=$actionsWidth}
        $controlActionsWidth=[Math]::Max(1,$actionsWidth)
        $stackTopButtons=($currentSendMinimumWidth+$currentExpandWidth+$actionGap)-gt$controlActionsWidth
        if($stackTopButtons){
            $script:CodexConversationSend.Left=0;$script:CodexConversationSend.Top=0;$script:CodexConversationSend.Width=$controlActionsWidth
            $script:CodexConversationComposerExpandButton.Left=0;$script:CodexConversationComposerExpandButton.Top=$script:CodexConversationSend.Bottom+$actionGap;$script:CodexConversationComposerExpandButton.Width=$controlActionsWidth
            $buttonTop=$script:CodexConversationComposerExpandButton.Bottom+$actionGap
        }else{
            $script:CodexConversationComposerExpandButton.Top=0;$script:CodexConversationComposerExpandButton.Width=$currentExpandWidth;$script:CodexConversationComposerExpandButton.Left=[Math]::Max(0,$controlActionsWidth-$currentExpandWidth)
            $script:CodexConversationSend.Left=0;$script:CodexConversationSend.Top=0;$script:CodexConversationSend.Width=[Math]::Max(1,$script:CodexConversationComposerExpandButton.Left-$actionGap)
            $buttonTop=$script:CodexConversationSend.Bottom+$actionGap
        }
        $stackImageButtons=($currentAttachWidth+$currentClearWidth+$actionGap)-gt$controlActionsWidth
        if($stackImageButtons){
            $script:CodexConversationAttachButton.Left=0;$script:CodexConversationAttachButton.Top=$buttonTop;$script:CodexConversationAttachButton.Width=$controlActionsWidth
            $script:CodexConversationClearAttachmentsButton.Left=0;$script:CodexConversationClearAttachmentsButton.Top=$script:CodexConversationAttachButton.Bottom+$actionGap;$script:CodexConversationClearAttachmentsButton.Width=$controlActionsWidth
        }else{
            $script:CodexConversationAttachButton.Left=0;$script:CodexConversationAttachButton.Top=$buttonTop;$script:CodexConversationAttachButton.Width=$currentAttachWidth
            $script:CodexConversationClearAttachmentsButton.Left=$script:CodexConversationAttachButton.Right+$actionGap;$script:CodexConversationClearAttachmentsButton.Top=$buttonTop;$script:CodexConversationClearAttachmentsButton.Width=$currentClearWidth
        }
        $conversationGrip.Left=[Math]::Max(8,[int](($conversationComposer.ClientSize.Width-$conversationGrip.Width)/2));$conversationGrip.Top=5
        $requiredComposerHeight=Get-CodexConversationComposerMinimumHeight
        if($null-ne$script:CodexConversationComposerRowStyle-and$script:CodexConversationComposerRowStyle.Height-lt($requiredComposerHeight-1)){Update-CodexConversationComposerHeight}
    }
    $script:CodexConversationComposerLayoutHandler=$layoutConversationComposer
    $layoutConversationHeader={
        if($script:CodexConversationHeaderLayoutInProgress){return}
        $script:CodexConversationHeaderLayoutInProgress=$true
        try{
            $width=[Math]::Max(1,$conversationHeader.ClientSize.Width)
            $compactHeader=$width-lt900
            $headerGap=if($compactHeader){ConvertTo-WorkflowDpiPixels 6 4}else{ConvertTo-WorkflowDpiPixels 10 7}
            $rowPadding=[Math]::Max((ConvertTo-WorkflowDpiPixels 8 6),$headerGap)
            $titleTop=ConvertTo-WorkflowDpiPixels 11 8
            $buttonTop=ConvertTo-WorkflowDpiPixels 13 10
            $conversationTitleTop=$titleTop
            $script:CodexConversationTitle.Top=$conversationTitleTop
            $script:CodexConversationTitle.Height=[Math]::Max((ConvertTo-WorkflowDpiPixels 34 30),$script:CodexConversationTitle.PreferredSize.Height+2)
            if($compactHeader){
                $conversationTerminal.Width=ConvertTo-WorkflowDpiPixels 90 76
                $conversationBack.Width=ConvertTo-WorkflowDpiPixels 90 76
                $conversationFiles.Width=ConvertTo-WorkflowDpiPixels 76 64
                $conversationReload.Width=ConvertTo-WorkflowDpiPixels 90 76
                $conversationStop.Width=ConvertTo-WorkflowDpiPixels 80 68
                $conversationPreviousUser.Width=ConvertTo-WorkflowDpiPixels 32 28
            }else{
                $conversationTerminal.Width=ConvertTo-WorkflowDpiPixels 100 84
                $conversationBack.Width=ConvertTo-WorkflowDpiPixels 106 90
                $conversationFiles.Width=ConvertTo-WorkflowDpiPixels 84 72
                $conversationReload.Width=ConvertTo-WorkflowDpiPixels 102 86
                $conversationStop.Width=ConvertTo-WorkflowDpiPixels 84 72
                $conversationPreviousUser.Width=ConvertTo-WorkflowDpiPixels 38 32
            }
            foreach($button in @($conversationPreviousUser,$conversationStop,$conversationReload,$conversationFiles,$conversationBack,$conversationTerminal)){
                $button.Top=$buttonTop
            }
            $right=$width-12
            $conversationTerminal.Left=$right-$conversationTerminal.Width;$right=$conversationTerminal.Left-$headerGap
            $conversationBack.Left=$right-$conversationBack.Width;$right=$conversationBack.Left-$headerGap
            $conversationFiles.Left=$right-$conversationFiles.Width;$right=$conversationFiles.Left-$headerGap
            $conversationReload.Left=$right-$conversationReload.Width;$right=$conversationReload.Left-$headerGap
            $conversationStop.Left=$right-$conversationStop.Width;$right=$conversationStop.Left-$headerGap
            $conversationPreviousUser.Left=$right-$conversationPreviousUser.Width
            $titleRight=[Math]::Max($script:CodexConversationTitle.Left+1,$conversationPreviousUser.Left-16)
            $script:CodexConversationTitle.Width=[Math]::Max(1,$titleRight-$script:CodexConversationTitle.Left)

            $searchFontHeight=[Windows.Forms.TextRenderer]::MeasureText('查找',$script:CodexConversationSearchBox.Font).Height
            $searchHeight=[Math]::Max((ConvertTo-WorkflowDpiPixels 28 26),$searchFontHeight+(ConvertTo-WorkflowDpiPixels 8 6))
            $searchWidth=if($compactHeader){ConvertTo-WorkflowDpiPixels 132 116}else{ConvertTo-WorkflowDpiPixels 160 140}
            $searchLabelWidth=[Math]::Max((ConvertTo-WorkflowDpiPixels 34 30),[Windows.Forms.TextRenderer]::MeasureText('查找',$script:CodexConversationSearchLabel.Font).Width+4)
            $statusDesiredWidth=[Math]::Min((ConvertTo-WorkflowDpiPixels 270 230),[Math]::Max((ConvertTo-WorkflowDpiPixels 160 140),[int]($width*0.30)))
            $script:CodexConversationStatus.Width=[Math]::Max((ConvertTo-WorkflowDpiPixels 100 80),$statusDesiredWidth)
            $script:CodexConversationStatus.Left=[Math]::Max(20,$width-$script:CodexConversationStatus.Width-12)
            $searchRight=$script:CodexConversationStatus.Left-$headerGap
            $script:CodexConversationSearchFrame.Width=$searchWidth
            $script:CodexConversationSearchFrame.Left=[Math]::Max(20,$searchRight-$searchLabelWidth-$headerGap-$searchWidth)
            $script:CodexConversationSearchFrame.Height=$searchHeight
            $script:CodexConversationSearchLabel.Left=[Math]::Max(20,$script:CodexConversationSearchFrame.Left-$headerGap-$searchLabelWidth)
            $script:CodexConversationSearchLabel.Width=$searchLabelWidth

            $firstRowBottom=$script:CodexConversationTitle.Bottom
            foreach($button in @($conversationPreviousUser,$conversationStop,$conversationReload,$conversationFiles,$conversationBack,$conversationTerminal)){$firstRowBottom=[Math]::Max($firstRowBottom,$button.Bottom)}
            $secondRowTop=$firstRowBottom+$rowPadding
            $secondRowHeight=[Math]::Max($searchHeight,$script:CodexConversationStatus.PreferredSize.Height+2)
            if($null-ne$script:CodexConversationSessionSelector-and$script:CodexConversationSessionSelector.Visible){
                $selectorMaxWidth=[Math]::Max(1,$script:CodexConversationSearchLabel.Left-$headerGap-20)
                $script:CodexConversationSessionSelector.Left=20
                $script:CodexConversationSessionSelector.Top=$secondRowTop
                $script:CodexConversationSessionSelector.Height=$secondRowHeight
                $script:CodexConversationSessionSelector.ItemHeight=[Math]::Max((ConvertTo-WorkflowDpiPixels 28 24),$secondRowHeight-2)
                $script:CodexConversationSessionSelector.Width=[Math]::Max(1,[Math]::Min((ConvertTo-WorkflowDpiPixels 360 300),$selectorMaxWidth))
            }
            $script:CodexConversationSearchLabel.Top=$secondRowTop
            $script:CodexConversationSearchLabel.Height=$secondRowHeight
            $script:CodexConversationSearchFrame.Top=$secondRowTop
            $script:CodexConversationStatus.Top=$secondRowTop
            $script:CodexConversationStatus.Height=$secondRowHeight
            $headerHeight=$secondRowTop+$secondRowHeight+$rowPadding
            if($null-ne$script:CodexConversationLayout-and$script:CodexConversationLayout.RowStyles.Count-gt0-and[Math]::Abs($script:CodexConversationLayout.RowStyles[0].Height-$headerHeight)-gt1){$script:CodexConversationLayout.RowStyles[0].Height=$headerHeight}
        }finally{$script:CodexConversationHeaderLayoutInProgress=$false}
    }
    $script:CodexConversationHeaderLayoutHandler=$layoutConversationHeader
    $conversationHeader.Add_Resize($layoutConversationHeader)
    $conversationComposer.Add_Resize($layoutConversationComposer)
    $conversationComposerLayout.Add_Resize($layoutConversationComposer)
    $conversationActions.Add_Resize($layoutConversationComposer)
    $conversationLayout.Add_Resize({Update-CodexConversationComposerHeight})
    $script:CodexConversationPanel.Add_VisibleChanged({if($script:CodexConversationPanel.Visible){Refresh-CodexConversationVisibleSurface -ForceBubbleLayout}})
    $script:CodexConversationComposerExpandButton.Add_Click({Toggle-CodexConversationComposerExpanded})
    $conversationGrip.Add_DoubleClick({Toggle-CodexConversationComposerExpanded})
    $conversationGrip.Add_MouseDown({param($sender,$e);if($e.Button-eq[Windows.Forms.MouseButtons]::Left){$script:CodexConversationComposerDragActive=$true;$script:CodexConversationComposerDragStartY=[Windows.Forms.Cursor]::Position.Y;$script:CodexConversationComposerDragStartHeight=[int][Math]::Round($script:CodexConversationComposerRowStyle.Height);$sender.Capture=$true}})
    $conversationGrip.Add_MouseMove({param($sender,$e);if($script:CodexConversationComposerDragActive-and(([Windows.Forms.Control]::MouseButtons-band[Windows.Forms.MouseButtons]::Left)-ne0)){$requested=$script:CodexConversationComposerDragStartHeight+($script:CodexConversationComposerDragStartY-[Windows.Forms.Cursor]::Position.Y);[void](Set-CodexConversationComposerHeight $requested -FromDrag)}})
    $conversationGrip.Add_MouseUp({param($sender,$e);if($e.Button-eq[Windows.Forms.MouseButtons]::Left){$script:CodexConversationComposerDragActive=$false;$sender.Capture=$false}})
    & $layoutConversationHeader
    & $layoutConversationComposer
    Update-CodexConversationComposerHeight

    $fileTreePanel=New-Object Windows.Forms.Panel; $fileTreePanel.Dock='Fill'; $fileTreePanel.Margin=New-Object Windows.Forms.Padding(0); $fileTreePanel.BackColor=[Drawing.Color]::White; $conversationSplit.Panel2.Controls.Add($fileTreePanel); $script:CodexConversationFileTreePanel=$fileTreePanel
    $fileTreeLayout=New-Object Windows.Forms.TableLayoutPanel; $fileTreeLayout.Dock='Fill'; $fileTreeLayout.Margin=New-Object Windows.Forms.Padding(0); $fileTreeLayout.Padding=New-Object Windows.Forms.Padding(0); $fileTreeLayout.ColumnCount=1; $fileTreeLayout.RowCount=2; [void]$fileTreeLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))); [void]$fileTreeLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,82))); [void]$fileTreeLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))); $fileTreePanel.Controls.Add($fileTreeLayout)
    $fileTreeHeader=New-Object Windows.Forms.Panel; $fileTreeHeader.Dock='Fill'; $fileTreeHeader.Margin=New-Object Windows.Forms.Padding(0); $fileTreeHeader.BackColor=[Drawing.Color]::White; $fileTreeLayout.Controls.Add($fileTreeHeader,0,0); $script:CodexConversationFileTreeHeader=$fileTreeHeader
    $fileTreeTitle=Add-UiLabel $fileTreeHeader '当前目录' 14 10 150 24; $fileTreeTitle.Font=New-UiFont 10 ([Drawing.FontStyle]::Bold); $fileTreeTitle.ForeColor=[Drawing.Color]::FromArgb(15,23,42)
    $script:CodexConversationFileTreePathLabel=Add-UiLabel $fileTreeHeader '' 14 40 180 28 -Muted; $script:CodexConversationFileTreePathLabel.AutoEllipsis=$true
    $script:CodexConversationFileTreeRefreshButton=Add-UiButton $fileTreeHeader '刷新' 190 9 58 30
    $script:CodexConversationFileTreeCollapseButton=Add-UiButton $fileTreeHeader '收起' 254 9 58 30
    $script:CodexConversationFileTreeToolTip=New-Object Windows.Forms.ToolTip
    $fileTreeHeader.Add_Resize({
        $rightEdge=[Math]::Max(14,$fileTreeHeader.ClientSize.Width-12)
        $script:CodexConversationFileTreeCollapseButton.Left=$rightEdge-$script:CodexConversationFileTreeCollapseButton.Width
        $script:CodexConversationFileTreeRefreshButton.Left=$script:CodexConversationFileTreeCollapseButton.Left-$script:CodexConversationFileTreeRefreshButton.Width-6
        $fileTreeTitle.Width=[Math]::Max(60,$script:CodexConversationFileTreeRefreshButton.Left-24)
        $script:CodexConversationFileTreePathLabel.Width=[Math]::Max(40,$fileTreeHeader.ClientSize.Width-28)
    })
    $fileTreeHost=New-Object Windows.Forms.Panel; $fileTreeHost.Dock='Fill'; $fileTreeHost.Margin=New-Object Windows.Forms.Padding(0,0,0,0); $fileTreeHost.Padding=New-Object Windows.Forms.Padding(1); $fileTreeHost.BackColor=[Drawing.Color]::FromArgb(203,213,225); $fileTreeLayout.Controls.Add($fileTreeHost,0,1); $script:CodexConversationFileTreeHost=$fileTreeHost
    $script:CodexConversationFileTree=New-Object Windows.Forms.TreeView; $script:CodexConversationFileTree.Dock='Fill'; $script:CodexConversationFileTree.Margin=New-Object Windows.Forms.Padding(0); $script:CodexConversationFileTree.BorderStyle=[Windows.Forms.BorderStyle]::None; $script:CodexConversationFileTree.BackColor=[Drawing.Color]::White; $script:CodexConversationFileTree.Font=New-UiFont 9.5; $script:CodexConversationFileTree.ItemHeight=28; $script:CodexConversationFileTree.FullRowSelect=$true; $script:CodexConversationFileTree.HideSelection=$false; $script:CodexConversationFileTree.ShowNodeToolTips=$true; $script:CodexConversationFileTree.ShowLines=$true; $script:CodexConversationFileTree.ShowPlusMinus=$true; $fileTreeHost.Controls.Add($script:CodexConversationFileTree)
    $script:CodexConversationFileTreeContextMenu=New-Object Windows.Forms.ContextMenuStrip
     $fileTreeInsertItem=New-Object Windows.Forms.ToolStripMenuItem '添加路径到对话'
     $fileTreeOpenItem=New-Object Windows.Forms.ToolStripMenuItem '打开'
     $fileTreeLocateItem=New-Object Windows.Forms.ToolStripMenuItem '定位并选中'
     $fileTreeCopyItem=New-Object Windows.Forms.ToolStripMenuItem '复制'
     $fileTreePasteItem=New-Object Windows.Forms.ToolStripMenuItem '粘贴'
     $fileTreeDeleteItem=New-Object Windows.Forms.ToolStripMenuItem '删除'
     $fileTreePwdItem=New-Object Windows.Forms.ToolStripMenuItem '在 pwd 中打开'
     $fileTreePowerShellItem=New-Object Windows.Forms.ToolStripMenuItem '在 PowerShell 中打开'
     [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreeInsertItem); [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreeOpenItem); [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreeLocateItem); [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreeCopyItem); [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreePasteItem); [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreeDeleteItem); [void]$script:CodexConversationFileTreeContextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)); [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreePwdItem); [void]$script:CodexConversationFileTreeContextMenu.Items.Add($fileTreePowerShellItem)
    $script:CodexConversationFileTree.ContextMenuStrip=$script:CodexConversationFileTreeContextMenu
    $script:CodexConversationFileTree.Add_BeforeExpand({param($sender,$e);Load-CodexConversationFileTreeNode $e.Node})
    $script:CodexConversationFileTree.Add_NodeMouseClick({param($sender,$e);if($e.Button-eq[Windows.Forms.MouseButtons]::Right){$sender.SelectedNode=$e.Node}})
     $script:CodexConversationFileTree.Add_NodeMouseDoubleClick({param($sender,$e);if($null-ne$e.Node.Tag-and[string]$e.Node.Tag.Kind-eq'File'){[void](Open-CodexConversationFileTreeItem ([string]$e.Node.Tag.Path))}})
     $script:CodexConversationFileTree.Add_KeyDown({param($sender,$e);if($e.Control-and$e.KeyCode-eq[Windows.Forms.Keys]::C){[void](Copy-CodexConversationFileTreeItem);$e.Handled=$true;$e.SuppressKeyPress=$true}elseif($e.Control-and$e.KeyCode-eq[Windows.Forms.Keys]::V){[void](Paste-CodexConversationFileTreeItem);$e.Handled=$true;$e.SuppressKeyPress=$true}elseif($e.KeyCode-eq[Windows.Forms.Keys]::Delete){[void](Remove-CodexConversationFileTreeItem);$e.Handled=$true;$e.SuppressKeyPress=$true}})
    $script:CodexConversationFileTreeContextMenu.Add_Opening({
        $node=$script:CodexConversationFileTree.SelectedNode
        $available=$null-ne$node-and$null-ne$node.Tag-and[string]$node.Tag.Kind-in@('File','Directory')
         $isFile=$available-and[string]$node.Tag.Kind-eq'File'; $isRoot=$available-and[string]$node.Tag.Kind-eq'Directory'-and[bool]$node.Tag.IsRoot
         $pasteTargetAvailable=$false; try{$pasteTarget=Get-CodexConversationFileTreePasteDirectory $node;$pasteTargetAvailable=[IO.Directory]::Exists($pasteTarget)}catch{}
         $fileTreeInsertItem.Enabled=$available; $fileTreeOpenItem.Enabled=$available; $fileTreeLocateItem.Enabled=$isFile; $fileTreeCopyItem.Enabled=$available; $fileTreePasteItem.Enabled=(@(Get-CodexConversationFileTreeClipboardPaths).Count-gt0-and$pasteTargetAvailable); $fileTreeDeleteItem.Enabled=$available-and-not$isRoot; $fileTreePwdItem.Enabled=$available; $fileTreePowerShellItem.Enabled=$available
         $fileTreeOpenItem.Text=if($available-and[string]$node.Tag.Kind-eq'Directory'){'打开目录'}else{'打开'}
     })
     $fileTreeInsertItem.Add_Click({$node=$script:CodexConversationFileTree.SelectedNode;if($null-ne$node-and$null-ne$node.Tag){[void](Insert-CodexConversationFileTreePath ([string]$node.Tag.Path))}})
     $fileTreeOpenItem.Add_Click({$node=$script:CodexConversationFileTree.SelectedNode;if($null-ne$node-and$null-ne$node.Tag){[void](Open-CodexConversationFileTreeItem ([string]$node.Tag.Path))}})
     $fileTreeLocateItem.Add_Click({$node=$script:CodexConversationFileTree.SelectedNode;if($null-ne$node-and$null-ne$node.Tag){[void](Locate-CodexConversationFileTreeItem ([string]$node.Tag.Path))}})
     $fileTreeCopyItem.Add_Click({[void](Copy-CodexConversationFileTreeItem)})
     $fileTreePasteItem.Add_Click({[void](Paste-CodexConversationFileTreeItem)})
     $fileTreeDeleteItem.Add_Click({[void](Remove-CodexConversationFileTreeItem)})
    $fileTreePwdItem.Add_Click({$node=$script:CodexConversationFileTree.SelectedNode;if($null-ne$node-and$null-ne$node.Tag){[void](Open-CodexConversationFileTreeInPwd ([string]$node.Tag.Path))}})
    $fileTreePowerShellItem.Add_Click({$node=$script:CodexConversationFileTree.SelectedNode;if($null-ne$node-and$null-ne$node.Tag){[void](Open-CodexConversationFileTreeInPowerShell ([string]$node.Tag.Path))}})
    $script:CodexConversationFileTreeRefreshButton.Add_Click({Refresh-CodexConversationFileTree})
    $script:CodexConversationFileTreeCollapseButton.Add_Click({$script:CodexConversationFileTreeUserVisible=$false;Update-CodexConversationFileTreeLayout})
    $conversationFiles.Add_Click({$script:CodexConversationFileTreeUserVisible=$script:CodexConversationSplit.Panel2Collapsed;Update-CodexConversationFileTreeLayout})
    $conversationSplit.Add_Resize({Update-CodexConversationFileTreeLayout})
    $script:CodexConversationFileTreeCollapseButton.Left=[Math]::Max(14,$fileTreeHeader.ClientSize.Width-$script:CodexConversationFileTreeCollapseButton.Width-12)
    $script:CodexConversationFileTreeRefreshButton.Left=$script:CodexConversationFileTreeCollapseButton.Left-$script:CodexConversationFileTreeRefreshButton.Width-6
    $script:CodexConversationFileTreePathLabel.Width=[Math]::Max(40,$fileTreeHeader.ClientSize.Width-28)
    Update-CodexConversationFileTreeLayout
    $script:CodexConversationTimer=New-Object Windows.Forms.Timer; $script:CodexConversationTimer.Interval=250; $script:CodexConversationTimer.Add_Tick({
        try { Complete-ProjectCodexMessage }
        catch {
            $pollError = [string]$_.Exception.Message
            $pollNow = Get-Date
            if ($pollError -ne [string]$script:CodexConversationLastPollError -or ($pollNow - $script:CodexConversationLastPollErrorAt).TotalSeconds -ge 10) {
                Write-WorkflowLog ('Codex 会话轮询异常，保留当前会话状态：' + $pollError) 'ERROR'
                $script:CodexConversationLastPollError = $pollError
                $script:CodexConversationLastPollErrorAt = $pollNow
            }
        }
    })

    $script:RunningTasksPanel=New-Object Windows.Forms.Panel; $script:RunningTasksPanel.Dock='Fill'; $script:RunningTasksPanel.Padding=New-Object Windows.Forms.Padding(18); $script:RunningTasksPanel.BackColor=[Drawing.Color]::FromArgb(241,245,249); $script:RunningTasksPanel.Visible=$false; $right.Controls.Add($script:RunningTasksPanel)
    $runningLayout=New-Object Windows.Forms.TableLayoutPanel; $runningLayout.Dock='Fill'; $runningLayout.ColumnCount=1; $runningLayout.RowCount=3; $runningLayout.Margin=New-Object Windows.Forms.Padding(0); [void]$runningLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))); [void]$runningLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,72))); [void]$runningLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,220))); [void]$runningLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))); $script:RunningTasksPanel.Controls.Add($runningLayout)
    $runningHeader=New-Object Windows.Forms.Panel; $runningHeader.Dock='Fill'; $runningHeader.Margin=New-Object Windows.Forms.Padding(0); $runningHeader.BackColor=[Drawing.Color]::White; $runningLayout.Controls.Add($runningHeader,0,0)
    $runningTitle=Add-UiLabel $runningHeader '运行中任务' 20 12 280 28; $runningTitle.Font=New-UiFont 12 ([Drawing.FontStyle]::Bold); $runningTitle.ForeColor=[Drawing.Color]::FromArgb(15,23,42)
    Add-UiLabel $runningHeader '查看当前节点、实时输出和任务状态；停止任务会同时终止其子进程。' 20 40 650 24 -Muted | Out-Null
    $runningBack=Add-UiButton $runningHeader '返回工作流' 890 18 110 34; $runningBack.Anchor='Top,Right'; $script:RunningTaskBackButton=$runningBack
    $runningHeader.Add_Resize({$runningBack.Left=[Math]::Max(18,$runningHeader.ClientSize.Width-$runningBack.Width-18)})
    $gridHost=New-Object Windows.Forms.Panel; $gridHost.Dock='Fill'; $gridHost.Margin=New-Object Windows.Forms.Padding(0,8,0,8); $gridHost.Padding=New-Object Windows.Forms.Padding(12); $gridHost.BackColor=[Drawing.Color]::White; $runningLayout.Controls.Add($gridHost,0,1)
    $script:RunningTasksGrid=New-Object Windows.Forms.DataGridView; $script:RunningTasksGrid.Dock='Fill'; $script:RunningTasksGrid.ReadOnly=$true; $script:RunningTasksGrid.AllowUserToAddRows=$false; $script:RunningTasksGrid.AllowUserToDeleteRows=$false; $script:RunningTasksGrid.AllowUserToResizeRows=$false; $script:RunningTasksGrid.RowHeadersVisible=$false; $script:RunningTasksGrid.SelectionMode='FullRowSelect'; $script:RunningTasksGrid.MultiSelect=$false; $script:RunningTasksGrid.AutoGenerateColumns=$false; $script:RunningTasksGrid.RowTemplate.Height=32; $gridHost.Controls.Add($script:RunningTasksGrid)
    $runningNameColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $runningNameColumn.HeaderText='任务'; $runningNameColumn.AutoSizeMode='Fill'; $runningNameColumn.FillWeight=32; [void]$script:RunningTasksGrid.Columns.Add($runningNameColumn)
    $runningStatusColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $runningStatusColumn.HeaderText='状态'; $runningStatusColumn.Width=90; [void]$script:RunningTasksGrid.Columns.Add($runningStatusColumn)
    $runningNodeColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $runningNodeColumn.HeaderText='当前节点'; $runningNodeColumn.AutoSizeMode='Fill'; $runningNodeColumn.FillWeight=38; [void]$script:RunningTasksGrid.Columns.Add($runningNodeColumn)
    $runningDurationColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $runningDurationColumn.HeaderText='已运行'; $runningDurationColumn.Width=90; [void]$script:RunningTasksGrid.Columns.Add($runningDurationColumn)
    $runningPidColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $runningPidColumn.HeaderText='Worker PID'; $runningPidColumn.Width=90; [void]$script:RunningTasksGrid.Columns.Add($runningPidColumn)
    $detailHost=New-Object Windows.Forms.TableLayoutPanel; $detailHost.Dock='Fill'; $detailHost.Margin=New-Object Windows.Forms.Padding(0); $detailHost.ColumnCount=1; $detailHost.RowCount=2; [void]$detailHost.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))); [void]$detailHost.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,72))); [void]$detailHost.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))); $runningLayout.Controls.Add($detailHost,0,2)
    $runningDetailHeader=New-Object Windows.Forms.Panel; $runningDetailHeader.Dock='Fill'; $runningDetailHeader.Margin=New-Object Windows.Forms.Padding(0); $runningDetailHeader.BackColor=[Drawing.Color]::White; $detailHost.Controls.Add($runningDetailHeader,0,0)
    $script:RunningTaskTitle=Add-UiLabel $runningDetailHeader '请选择一个运行中的任务' 18 10 570 28; $script:RunningTaskTitle.Font=New-UiFont 10.5 ([Drawing.FontStyle]::Bold)
    $script:RunningTaskMeta=Add-UiLabel $runningDetailHeader '当前没有选中的任务。' 18 40 760 24 -Muted; $script:RunningTaskMeta.AutoEllipsis=$true; $script:RunningTaskMeta.Anchor='Top,Left,Right'
    $script:RunningTaskStopButton=Add-UiButton $runningDetailHeader '停止任务' 884 18 116 36 'Danger'; $script:RunningTaskStopButton.Anchor='Top,Right'; $script:RunningTaskStopButton.Enabled=$false
    $runningDetailHeader.Add_Resize({$script:RunningTaskStopButton.Left=[Math]::Max(18,$runningDetailHeader.ClientSize.Width-$script:RunningTaskStopButton.Width-18);$script:RunningTaskTitle.Width=[Math]::Max(120,$script:RunningTaskStopButton.Left-30);$script:RunningTaskMeta.Width=[Math]::Max(120,$script:RunningTaskStopButton.Left-30)})
    $runningLogHost=New-Object Windows.Forms.Panel; $runningLogHost.Dock='Fill'; $runningLogHost.Margin=New-Object Windows.Forms.Padding(0,8,0,0); $runningLogHost.Padding=New-Object Windows.Forms.Padding(14); $runningLogHost.BackColor=[Drawing.Color]::White; $detailHost.Controls.Add($runningLogHost,0,1)
    $script:RunningTaskLogBox=New-Object Windows.Forms.RichTextBox; $script:RunningTaskLogBox.Dock='Fill'; $script:RunningTaskLogBox.ReadOnly=$true; $script:RunningTaskLogBox.BorderStyle='None'; $script:RunningTaskLogBox.BackColor=[Drawing.Color]::FromArgb(15,23,42); $script:RunningTaskLogBox.ForeColor=[Drawing.Color]::FromArgb(226,232,240); $script:RunningTaskLogBox.Font=New-Object Drawing.Font('Consolas',9); $script:RunningTaskLogBox.WordWrap=$false; $script:RunningTaskLogBox.ScrollBars='Both'; $runningLogHost.Controls.Add($script:RunningTaskLogBox)
    $script:CommonPromptsPanel=New-Object Windows.Forms.Panel;$script:CommonPromptsPanel.Dock='Fill';$script:CommonPromptsPanel.Padding=New-Object Windows.Forms.Padding(18);$script:CommonPromptsPanel.BackColor=[Drawing.Color]::FromArgb(241,245,249);$script:CommonPromptsPanel.Visible=$false;$right.Controls.Add($script:CommonPromptsPanel)
    $promptPageLayout=New-Object Windows.Forms.TableLayoutPanel;$promptPageLayout.Dock='Fill';$promptPageLayout.ColumnCount=1;$promptPageLayout.RowCount=2;$promptPageLayout.Margin=New-Object Windows.Forms.Padding(0);[void]$promptPageLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)));[void]$promptPageLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,82)));[void]$promptPageLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)));$script:CommonPromptsPanel.Controls.Add($promptPageLayout)
    $promptPageHeader=New-Object Windows.Forms.Panel;$promptPageHeader.Dock='Fill';$promptPageHeader.Margin=New-Object Windows.Forms.Padding(0);$promptPageHeader.BackColor=[Drawing.Color]::White;$promptPageLayout.Controls.Add($promptPageHeader,0,0);$script:CommonPromptsHeader=$promptPageHeader
    $promptPageTitle=Add-UiLabel $promptPageHeader '常用提示词管理' 20 12 300 28;$promptPageTitle.Font=New-UiFont 12 ([Drawing.FontStyle]::Bold);$promptPageTitle.ForeColor=[Drawing.Color]::FromArgb(15,23,42);$promptPageTitle.AutoEllipsis=$true
    $promptPageDescription=Add-UiLabel $promptPageHeader '悬浮窗口不会阻塞主页面；每条提示词可包含多行并快速复制。' 20 43 660 24 -Muted;$promptPageDescription.AutoEllipsis=$true;$script:CommonPromptsDescriptionLabel=$promptPageDescription
    $promptBack=Add-UiButton $promptPageHeader '关闭' 890 20 110 34;$promptBack.Anchor='Top,Right';$script:CommonPromptBackButton=$promptBack
    $promptPageHeader.Add_Resize({
        $promptBack.Left=[Math]::Max(18,$promptPageHeader.ClientSize.Width-$promptBack.Width-18)
        $promptPageDescription.Width=[Math]::Max(120,$promptBack.Left-$promptPageDescription.Left-14)
        $promptPageTitle.Width=[Math]::Max(160,$promptBack.Left-$promptPageTitle.Left-18)
    })
    $promptContent=New-Object Windows.Forms.Panel;$promptContent.Dock='Fill';$promptContent.Margin=New-Object Windows.Forms.Padding(0,8,0,0);$promptContent.Padding=New-Object Windows.Forms.Padding(16);$promptContent.BackColor=[Drawing.Color]::White;$promptPageLayout.Controls.Add($promptContent,0,1)
    $promptContentLayout=New-Object Windows.Forms.TableLayoutPanel;$promptContentLayout.Dock='Fill';$promptContentLayout.ColumnCount=1;$promptContentLayout.RowCount=2;$promptContentLayout.Margin=New-Object Windows.Forms.Padding(0);[void]$promptContentLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)));[void]$promptContentLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,52)));[void]$promptContentLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)));$promptContent.Controls.Add($promptContentLayout)
    $promptActions=New-Object Windows.Forms.FlowLayoutPanel;$promptActions.Dock='Fill';$promptActions.Margin=New-Object Windows.Forms.Padding(0);$promptActions.FlowDirection='LeftToRight';$promptActions.WrapContents=$false;$promptContentLayout.Controls.Add($promptActions,0,0)
    $script:CommonPromptAddButton=Add-UiButton $promptActions '新增提示词' 0 0 104 34 'Primary';$script:CommonPromptEditButton=Add-UiButton $promptActions '编辑' 0 0 82 34;$script:CommonPromptDeleteButton=Add-UiButton $promptActions '删除' 0 0 82 34 'Danger';$script:CommonPromptCopyButton=Add-UiButton $promptActions '复制' 0 0 82 34
    foreach($button in @($script:CommonPromptAddButton,$script:CommonPromptEditButton,$script:CommonPromptDeleteButton,$script:CommonPromptCopyButton)){$button.Margin=New-Object Windows.Forms.Padding(0,0,8,0)}
    $script:CommonPromptList=New-Object Windows.Forms.ListBox;$script:CommonPromptList.Dock='Fill';$script:CommonPromptList.Margin=New-Object Windows.Forms.Padding(0,6,0,0);$script:CommonPromptList.HorizontalScrollbar=$false;$script:CommonPromptList.IntegralHeight=$false;$script:CommonPromptList.DrawMode=[Windows.Forms.DrawMode]::OwnerDrawVariable;$script:CommonPromptList.ItemHeight=52;$script:CommonPromptList.Tag='CommonPromptList';$script:CommonPromptList.Font=New-UiFont 10;$script:CommonPromptList.BackColor=[Drawing.Color]::White;$promptContentLayout.Controls.Add($script:CommonPromptList,0,1)
    $script:CommonPromptList.Add_MeasureItem({param($sender,$e);$index=[int]$e.Index;if($index-lt0-or$index-ge$sender.Items.Count){$e.ItemHeight=46;return};$item=Get-UiIndexedItemSafe $sender.Items $index;$text=if($null-ne$item){[string]$item}else{''};$width=[Math]::Max(120,$sender.ClientSize.Width-42);$size=$e.Graphics.MeasureString($text,$sender.Font,$width);$e.ItemHeight=[Math]::Max(46,[int][Math]::Ceiling($size.Height)+18)})
    $script:CommonPromptList.Add_DrawItem({param($sender,$e);$index=[int]$e.Index;if($index-lt0-or$index-ge$sender.Items.Count){return};$selected=($e.State-band[Windows.Forms.DrawItemState]::Selected)-eq[Windows.Forms.DrawItemState]::Selected;$background=if($selected){[Drawing.Color]::FromArgb(239,246,255)}elseif(($index%2)-eq1){[Drawing.Color]::FromArgb(248,250,252)}else{[Drawing.Color]::White};$foreground=if($selected){[Drawing.Color]::FromArgb(30,64,175)}else{[Drawing.Color]::FromArgb(30,41,59)};$backgroundBrush=New-Object Drawing.SolidBrush($background);$textBrush=New-Object Drawing.SolidBrush($foreground);try{$e.Graphics.FillRectangle($backgroundBrush,$e.Bounds);$item=Get-UiIndexedItemSafe $sender.Items $index;$text=if($null-ne$item){[string]$item}else{''};$textRectangle=New-Object Drawing.RectangleF(($e.Bounds.Left+18),($e.Bounds.Top+8),[Math]::Max(1,$e.Bounds.Width-30),[Math]::Max(1,$e.Bounds.Height-14));$format=New-Object Drawing.StringFormat;$format.LineAlignment=[Drawing.StringAlignment]::Near;$format.Trimming=[Drawing.StringTrimming]::EllipsisWord;$e.Graphics.DrawString($text,$sender.Font,$textBrush,$textRectangle,$format);$format.Dispose();$linePen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(226,232,240));try{$e.Graphics.DrawLine($linePen,$e.Bounds.Left+12,$e.Bounds.Bottom-1,$e.Bounds.Right-12,$e.Bounds.Bottom-1)}finally{$linePen.Dispose()};if($selected){$accentPen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(59,130,246),3);try{$e.Graphics.DrawLine($accentPen,$e.Bounds.Left+3,$e.Bounds.Top+8,$e.Bounds.Left+3,$e.Bounds.Bottom-8)}finally{$accentPen.Dispose()}}}finally{$backgroundBrush.Dispose();$textBrush.Dispose()}})
    $script:CommonPromptList.Add_SizeChanged({$script:CommonPromptList.Invalidate()})

    $script:SessionManagerPanel=New-Object Windows.Forms.Panel; $script:SessionManagerPanel.Dock='Fill'; $script:SessionManagerPanel.Padding=New-Object Windows.Forms.Padding(18); $script:SessionManagerPanel.BackColor=[Drawing.Color]::FromArgb(241,245,249); $script:SessionManagerPanel.Visible=$false; $right.Controls.Add($script:SessionManagerPanel)
    $sessionLayout=New-Object Windows.Forms.TableLayoutPanel; $sessionLayout.Dock='Fill'; $sessionLayout.ColumnCount=1; $sessionLayout.RowCount=2; $sessionLayout.Margin=New-Object Windows.Forms.Padding(0); [void]$sessionLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))); [void]$sessionLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,82))); [void]$sessionLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))); $script:SessionManagerPanel.Controls.Add($sessionLayout)
    $sessionHeader=New-Object Windows.Forms.Panel; $sessionHeader.Dock='Fill'; $sessionHeader.Margin=New-Object Windows.Forms.Padding(0); $sessionHeader.BackColor=[Drawing.Color]::White; $sessionLayout.Controls.Add($sessionHeader,0,0)
    $sessionTitle=Add-UiLabel $sessionHeader '项目会话管理' 20 12 300 28; $sessionTitle.Font=New-UiFont 12 ([Drawing.FontStyle]::Bold); $sessionTitle.ForeColor=[Drawing.Color]::FromArgb(15,23,42)
    Add-UiLabel $sessionHeader '查看进行中、工作流占用、已完成和尚未创建的项目会话；双击可直接进入。' 20 43 650 24 -Muted | Out-Null
    $sessionBack=Add-UiButton $sessionHeader '返回工作流' 890 20 110 34; $sessionBack.Anchor='Top,Right'
    $script:SessionManagerOpenButton=Add-UiButton $sessionHeader '打开会话' 770 20 110 34 'Primary'; $script:SessionManagerOpenButton.Anchor='Top,Right'; $script:SessionManagerOpenButton.Enabled=$false
    $script:SessionManagerRefreshButton=Add-UiButton $sessionHeader '刷新' 682 20 78 34; $script:SessionManagerRefreshButton.Anchor='Top,Right'
    $sessionHeader.Add_Resize({$sessionBack.Left=[Math]::Max(700,$sessionHeader.ClientSize.Width-$sessionBack.Width-18);$script:SessionManagerOpenButton.Left=$sessionBack.Left-$script:SessionManagerOpenButton.Width-10;$script:SessionManagerRefreshButton.Left=$script:SessionManagerOpenButton.Left-$script:SessionManagerRefreshButton.Width-10})
    $sessionGridHost=New-Object Windows.Forms.Panel; $sessionGridHost.Dock='Fill'; $sessionGridHost.Margin=New-Object Windows.Forms.Padding(0,8,0,0); $sessionGridHost.Padding=New-Object Windows.Forms.Padding(12); $sessionGridHost.BackColor=[Drawing.Color]::White; $sessionLayout.Controls.Add($sessionGridHost,0,1)
    $script:SessionManagerGrid=New-Object Windows.Forms.DataGridView; $script:SessionManagerGrid.Dock='Fill'; $script:SessionManagerGrid.ReadOnly=$true; $script:SessionManagerGrid.AllowUserToAddRows=$false; $script:SessionManagerGrid.AllowUserToDeleteRows=$false; $script:SessionManagerGrid.AllowUserToResizeRows=$false; $script:SessionManagerGrid.RowHeadersVisible=$false; $script:SessionManagerGrid.SelectionMode='FullRowSelect'; $script:SessionManagerGrid.MultiSelect=$false; $script:SessionManagerGrid.AutoGenerateColumns=$false; $script:SessionManagerGrid.RowTemplate.Height=34; $sessionGridHost.Controls.Add($script:SessionManagerGrid)
    $sessionProjectColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $sessionProjectColumn.HeaderText='项目'; $sessionProjectColumn.AutoSizeMode='Fill'; $sessionProjectColumn.FillWeight=22; [void]$script:SessionManagerGrid.Columns.Add($sessionProjectColumn)
    $sessionStatusColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $sessionStatusColumn.HeaderText='状态'; $sessionStatusColumn.Width=104; [void]$script:SessionManagerGrid.Columns.Add($sessionStatusColumn)
    $sessionDescriptionColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $sessionDescriptionColumn.HeaderText='会话描述'; $sessionDescriptionColumn.AutoSizeMode='Fill'; $sessionDescriptionColumn.FillWeight=18; [void]$script:SessionManagerGrid.Columns.Add($sessionDescriptionColumn)
    $sessionIdColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $sessionIdColumn.HeaderText='Session ID'; $sessionIdColumn.Width=165; [void]$script:SessionManagerGrid.Columns.Add($sessionIdColumn)
    $sessionModelColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $sessionModelColumn.HeaderText='模型'; $sessionModelColumn.Width=112; [void]$script:SessionManagerGrid.Columns.Add($sessionModelColumn)
    $sessionDirectoryColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $sessionDirectoryColumn.HeaderText='默认工作目录'; $sessionDirectoryColumn.AutoSizeMode='Fill'; $sessionDirectoryColumn.FillWeight=34; [void]$script:SessionManagerGrid.Columns.Add($sessionDirectoryColumn)
    $sessionUpdatedColumn=New-Object Windows.Forms.DataGridViewTextBoxColumn; $sessionUpdatedColumn.HeaderText='更新时间'; $sessionUpdatedColumn.Width=150; [void]$script:SessionManagerGrid.Columns.Add($sessionUpdatedColumn)
    $script:Canvas.Add_Paint({
        param($sender, $e)
        try {
            Paint-WorkflowCanvas $sender $e
            $script:CanvasRenderError = $null
        } catch {
            $script:CanvasRenderError = $_.Exception.Message
            Write-WorkflowLog ('画布绘制失败：' + $script:CanvasRenderError) 'ERROR'
        }
    })
    $script:Canvas.Add_Resize({ Update-CanvasExtent; $script:Canvas.Invalidate() })
    $script:Canvas.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -notin @([Windows.Forms.MouseButtons]::Left,[Windows.Forms.MouseButtons]::Right)) { return }
        [void]$sender.Focus()
        $point = Get-CanvasMousePoint $sender $e
        if ($null -eq $point) { return }
        $x = ConvertTo-CanvasInt $point.X; $y = ConvertTo-CanvasInt $point.Y
        $node = Get-NodeAt $x $y
        if($e.Button -eq [Windows.Forms.MouseButtons]::Right){
            $script:CanvasContextPoint=$point
            $script:SelectedNode=$node
            $script:SelectedEdge=if($null-eq$node){Get-EdgeAt $x $y}else{$null}
            $sender.Invalidate()
            $script:CanvasContextMenu.Show($sender,$e.Location)
            return
        }
        $inlineHit = Get-CanvasInlineVariableHit $x $y
        if ($null -ne $inlineHit) {
            $hitKey = [string]$inlineHit.Node.Id + ':' + [string]$inlineHit.Index
            $now = Get-Date
            if ($script:CanvasInlineVariableLastKey -eq $hitKey -and ($now - $script:CanvasInlineVariableLastAt).TotalMilliseconds -lt 350) { return }
            $script:CanvasInlineVariableLastKey = $hitKey; $script:CanvasInlineVariableLastAt = $now
            $script:SelectedNode = $inlineHit.Node; $script:SelectedEdge = $null
            [void](Invoke-CanvasInlineVariableEdit $inlineHit)
            return
        }
        if ($null -eq $node) {
            $script:SelectedNode = $null
            $script:SelectedEdge = Get-EdgeAt $x $y
            $sender.Invalidate()
            return
        }
        $script:SelectedNode = $node
        $script:SelectedEdge = $null
        $nodeX = ConvertTo-CanvasInt $node.X
        $nodeY = ConvertTo-CanvasInt $node.Y
        $nodeWidth = ConvertTo-CanvasInt $node.Width
        if ($x -ge ($nodeX + $nodeWidth - 24)) {
            $script:ConnectingFrom = $node; $script:ConnectPoint = New-Object Drawing.Point($x, $y)
        } else {
            $script:DraggingNode = $node; $script:DragOffset = New-Object Drawing.Point((Get-CanvasDelta $x $nodeX), (Get-CanvasDelta $y $nodeY))
        }
        $sender.Invalidate()
    })
    $script:Canvas.Add_MouseMove({
        param($sender, $e)
        $point = Get-CanvasMousePoint $sender $e
        if ($null -eq $point) { return }
        $x = ConvertTo-CanvasInt $point.X; $y = ConvertTo-CanvasInt $point.Y
        if ($null -ne $script:ConnectingFrom) { $script:ConnectPoint = New-Object Drawing.Point($x, $y); $sender.Invalidate(); return }
        if ($null -ne $script:DraggingNode) {
            $script:DraggingNode.X = [Math]::Max(10, (Get-CanvasDelta $x $script:DragOffset.X)); $script:DraggingNode.Y = [Math]::Max(10, (Get-CanvasDelta $y $script:DragOffset.Y)); Update-CanvasExtent; $sender.Invalidate()
        }
    })
    $script:Canvas.Add_MouseUp({
        param($sender, $e)
        $point = Get-CanvasMousePoint $sender $e
        if ($null -eq $point) { return }
        $x = ConvertTo-CanvasInt $point.X; $y = ConvertTo-CanvasInt $point.Y
        if ($null -ne $script:ConnectingFrom) {
            $target = Get-NodeAt $x $y
            if ($null -ne $target) { Add-WorkflowEdge ([string]$script:ConnectingFrom.Id) ([string]$target.Id) }
            $script:ConnectingFrom = $null; $script:ConnectPoint = $null; $sender.Invalidate()
        }
        $script:DraggingNode = $null; $script:DragOffset = $null
    })
    $script:Canvas.Add_MouseDoubleClick({
        param($sender, $e)
        $point = Get-CanvasMousePoint $sender $e
        if ($null -eq $point) { return }
        $pointX = ConvertTo-CanvasInt $point.X; $pointY = ConvertTo-CanvasInt $point.Y
        if ($null -ne (Get-CanvasInlineVariableHit $pointX $pointY)) { return }
        $node = Get-NodeAt $pointX $pointY
        if ($null -ne $node -and (Show-NodeEditor $node) -eq 'OK') { $sender.Invalidate() }
    })
    $script:Canvas.Add_KeyDown({ param($sender, $e); Invoke-CanvasDeleteShortcut $e; Invoke-CanvasClipboardShortcut $e })
    $script:Canvas.TabStop = $true
    $form.Add_KeyDown({
        param($sender, $e)
        if ($null -ne $script:Canvas -and $script:Canvas.ContainsFocus) { Invoke-CanvasDeleteShortcut $e; Invoke-CanvasClipboardShortcut $e }
    })

    $script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel; $script:StatusLabel.Text = '后台调度器初始化中'; $status = New-Object System.Windows.Forms.StatusStrip; $status.Items.Add($script:StatusLabel) | Out-Null; $form.Controls.Add($status)
    $form.Controls.SetChildIndex($status, 2); $form.Controls.SetChildIndex($header, 1); $form.Controls.SetChildIndex($body, 0)

    $script:WorkflowList.Add_SelectedIndexChanged({
        if ($script:BindingWorkflow) { return }
        $conversationVisible = $null -ne $script:CodexConversationPanel -and $script:CodexConversationPanel.Visible
        if ($conversationVisible) {
            if ($script:WorkflowList.SelectedIndex -ge 0) { $script:CurrentWorkflow = $script:WorkflowList.SelectedItem }
        } else {
            Bind-CurrentWorkflow
        }
    })
    $script:WorkflowList.Add_MouseDown({
        param($sender,$e)
        $index=$sender.IndexFromPoint($e.Location)
        if($index-ge0){
            $sender.SelectedIndex=$index
            if($e.Button-eq[Windows.Forms.MouseButtons]::Left){
                $conversationVisible = $null -ne $script:CodexConversationPanel -and $script:CodexConversationPanel.Visible
                if(-not$conversationVisible){Bind-CurrentWorkflow}
            }
        }
    })
    $script:WorkflowList.Add_MouseDoubleClick({
        param($sender,$e)
        if($e.Button-ne[Windows.Forms.MouseButtons]::Left){return}
        $index=$sender.IndexFromPoint($e.Location)
        if($index-ge0){$sender.SelectedIndex=$index;Bind-CurrentWorkflow}
    })
    $script:WorkflowList.Add_KeyDown({param($sender,$e);Invoke-WorkflowListClipboardShortcut $e})
    $script:ProjectSelector.Add_SelectedIndexChanged({ if (-not $script:BindingWorkflow) { Bind-CurrentProject } })
    $script:WorkflowNameBox.Add_TextChanged({ if (-not $script:BindingWorkflow -and $null -ne $script:CurrentWorkflow) { $script:CurrentWorkflow.Name = $script:WorkflowNameBox.Text } })
    $script:WorkflowNameBox.Add_Leave({ Refresh-WorkflowList })
    $script:WorkflowEnabled.Add_CheckedChanged({
        if ($script:BindingWorkflow -or $null -eq $script:CurrentWorkflow) { return }
        $script:CurrentWorkflow.Enabled = $script:WorkflowEnabled.Checked
        if ($script:WorkflowEnabled.Checked) {
            try { Sync-WorkflowScheduleFromControls -Validate } catch {
                $script:BindingWorkflow = $true; $script:WorkflowEnabled.Checked = $false; $script:BindingWorkflow = $false; $script:CurrentWorkflow.Enabled = $false
                Show-Message $_.Exception.Message '定时配置无效' ([Windows.Forms.MessageBoxIcon]::Warning)
            }
        }
        Update-WorkflowNextRunLabel
    })
    $script:ScheduleModeBox.Add_SelectedIndexChanged({
        if ($script:BindingWorkflow -or $null -eq $script:CurrentWorkflow) { return }
        $script:BindingWorkflow = $true
        Set-ScheduleKindOptions (Get-SelectedScheduleMode) 'Interval'
        $script:BindingWorkflow = $false
        Update-ScheduleEditorVisibility
        Sync-WorkflowScheduleFromControls
    })
    $script:ScheduleKindBox.Add_SelectedIndexChanged({ if (-not $script:BindingWorkflow) { Update-ScheduleEditorVisibility; Sync-WorkflowScheduleFromControls } })
    $script:IntervalBox.Add_ValueChanged({ Sync-WorkflowScheduleFromControls })
    $script:ScheduleDayBox.Add_ValueChanged({ Sync-WorkflowScheduleFromControls })
    $script:ScheduleTimeBox.Add_Leave({ try { Sync-WorkflowScheduleFromControls -Validate } catch { Show-Message $_.Exception.Message '时间格式无效' ([Windows.Forms.MessageBoxIcon]::Warning) } })
    $script:ScheduleWeekdaysBox.Add_Leave({ try { Sync-WorkflowScheduleFromControls -Validate } catch { Show-Message $_.Exception.Message '每周配置无效' ([Windows.Forms.MessageBoxIcon]::Warning) } })
    $scheduleButton.Add_Click({ Show-WorkflowScheduleEditor })
    $saveWorkflow.Add_Click({ try { Sync-WorkflowScheduleFromControls -Validate; Save-Workflows } catch { Show-Message $_.Exception.Message '保存失败' ([Windows.Forms.MessageBoxIcon]::Warning) } })
    $runWorkflow.Add_Click({ $script:CurrentWorkflow = $script:WorkflowList.SelectedItem; Start-WorkflowJob $script:CurrentWorkflow -Manual })
    $sessionManager.Add_Click({ Show-SessionManagerPage })
    $runningTasks.Add_Click({ Show-RunningTasksPage })
    $commonPrompts.Add_Click({ Show-CommonPromptsPage })
    $globalSettings.Add_Click({ Show-GlobalSettingsEditor })
    $workflowAi.Add_Click({ Show-WorkflowAiConversation })
    $addStart.Add_Click({ Add-NewNode 'Start' }); $addEnd.Add_Click({ Add-NewNode 'End' }); $addHttp.Add_Click({ Add-NewNode 'HttpRequest' }); $addRead.Add_Click({ Add-NewNode 'EnvRead' }); $addWrite.Add_Click({ Add-NewNode 'EnvWrite' }); $addVariable.Add_Click({ Add-NewNode 'Variable' }); $addCmd.Add_Click({ Add-NewNode 'Cmd' }); $addPython.Add_Click({ Add-NewNode 'Python' }); $addCodex.Add_Click({ Add-NewNode 'Codex' }); $addIf.Add_Click({ Add-NewNode 'If' }); $addForEach.Add_Click({ Add-NewNode 'ForEach' }); $addLoopEnd.Add_Click({ Add-NewNode 'LoopEnd' }); $addDelay.Add_Click({ Add-NewNode 'Delay' }); $addBalloon.Add_Click({ Add-NewNode 'Balloon' }); $deleteNode.Add_Click({ Remove-SelectedCanvasItem })
    $newProject.Add_Click({ $project=Show-ProjectEditor; if($null -ne $project){$script:Projects=@($script:Projects)+$project;$script:CurrentProject=$project;Save-Projects;Refresh-ProjectSelector} })
    $editProject.Add_Click({ if($null -eq $script:CurrentProject){Show-Message '“无项目”无需编辑。' '项目' ([Windows.Forms.MessageBoxIcon]::Information);return}; $project=Show-ProjectEditor $script:CurrentProject; if($null -ne $project){Save-Projects;Refresh-ProjectSelector;Update-ProjectInfo} })
    $deleteProject.Add_Click({
        if($null -eq $script:CurrentProject){Show-Message '不能删除“无项目”。' '项目' ([Windows.Forms.MessageBoxIcon]::Information);return}
        $answer=[Windows.Forms.MessageBox]::Show(('删除项目“' + [string]$script:CurrentProject.Name + '”？项目内工作流将移动到“无项目”。'),'删除项目',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
        if($answer -eq 'Yes'){$id=[string]$script:CurrentProject.Id;foreach($workflow in @($script:Workflows|Where-Object{[string](Get-UiConfigValue $_ 'ProjectId' '') -eq $id})){if($null-eq$workflow.PSObject.Properties['ProjectId']){$workflow|Add-Member NoteProperty ProjectId ''}else{$workflow.ProjectId=''}};$script:Projects=@($script:Projects|Where-Object{[string]$_.Id -ne $id});$script:CurrentProject=$null;Save-Projects;Save-Workflows;Refresh-ProjectSelector}
    })
    $openProject.Add_Click({ Open-CurrentProjectPath }); $openVSCode.Add_Click({ Open-CurrentProjectInVSCode }); $projectChat.Add_Click({ Show-CurrentProjectConversationEntry }); $projectTerminal.Add_Click({ Open-CurrentProjectCodexTerminal })
    $script:CodexConversationSearchBox.Add_TextChanged({ Reset-CodexConversationSearchState })
    $script:CodexConversationSearchBox.Add_KeyDown({ param($sender,$e); if($e.KeyCode-eq[Windows.Forms.Keys]::Enter){[void](Find-PreviousCodexConversationText $sender.Text);$e.SuppressKeyPress=$true;$e.Handled=$true}elseif($e.KeyCode-eq[Windows.Forms.Keys]::Escape){Reset-CodexConversationSearchState -ClearText;Set-CodexConversationStatus '已清空查找';$e.SuppressKeyPress=$true;$e.Handled=$true} })
    $conversationBack.Add_Click({ Show-WorkflowWorkspace }); $conversationReload.Add_Click({ Refresh-CodexConversation }); $conversationStop.Add_Click({[void](Stop-CurrentCodexConversation)}); $conversationPreviousUser.Add_Click({ [void](Go-To-PreviousCodexUserMessage) }); $conversationTerminal.Add_Click({ Open-CurrentProjectCodexTerminal }); $script:CodexConversationSend.Add_Click({ Send-CodexConversationMessage }); $script:CodexConversationAttachButton.Add_Click({ [void](Paste-CodexConversationClipboardImage) }); $script:CodexConversationClearAttachmentsButton.Add_Click({ Clear-CodexConversationPendingImages })
     $script:CodexConversationSessionSelector.Add_SelectedIndexChanged({param($sender,$e);Request-CodexConversationProjectSessionSwitch $sender})
    $runningBack.Add_Click({ Show-WorkflowWorkspace })
    $promptBack.Add_Click({ Close-CommonPromptsWindow })
    $sessionBack.Add_Click({ Show-WorkflowWorkspace })
    $script:SessionManagerRefreshButton.Add_Click({ Refresh-SessionManagerView -Force })
    $script:SessionManagerOpenButton.Add_Click({ Open-SelectedManagedSession })
    $script:SessionManagerGrid.Add_SelectionChanged({ if($null-ne$script:SessionManagerOpenButton){$script:SessionManagerOpenButton.Enabled=-not[string]::IsNullOrWhiteSpace((Get-SelectedSessionManagerProjectId))} })
    $script:SessionManagerGrid.Add_CellDoubleClick({ param($sender,$e); if($e.RowIndex-ge0){Open-SelectedManagedSession} })
    $script:RunningTasksGrid.Add_SelectionChanged({ Refresh-RunningTaskDetails })
    $script:CommonPromptList.Add_SelectedIndexChanged({Update-CommonPromptActionState})
    $script:CommonPromptList.Add_MouseDoubleClick({[void](Copy-SelectedCommonPrompt)})
    $script:CommonPromptAddButton.Add_Click({Add-CommonPrompt})
    $script:CommonPromptEditButton.Add_Click({Edit-SelectedCommonPrompt})
    $script:CommonPromptDeleteButton.Add_Click({Remove-SelectedCommonPrompt})
    $script:CommonPromptCopyButton.Add_Click({[void](Copy-SelectedCommonPrompt)})
    $script:RunningTaskStopButton.Add_Click({
        $workflowId=Get-SelectedRunningTaskId
        if([string]::IsNullOrWhiteSpace($workflowId)-or-not$script:RunningJobs.ContainsKey($workflowId)){return}
        $record=$script:RunningJobs[$workflowId]
        $answer=[Windows.Forms.MessageBox]::Show(('确定停止任务“'+[string]$record.WorkflowName+'”？其 CMD/Codex 等子进程也会被终止。'),'停止任务',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
        if($answer-eq[Windows.Forms.DialogResult]::Yes){[void](Stop-WorkflowJob $workflowId)}
    })
    $script:CodexConversationInput.Add_KeyDown({
        param($sender,$e)
        if($e.Control-and$e.KeyCode-eq[Windows.Forms.Keys]::V-and[Windows.Forms.Clipboard]::ContainsImage()){
            $e.SuppressKeyPress=$true
            $e.Handled=$true
            [void](Paste-CodexConversationClipboardImage)
        }elseif($e.Modifiers-eq[Windows.Forms.Keys]::None-and(Move-CodexConversationInputCaretAtBoundary $sender $e.KeyCode)){
            $e.SuppressKeyPress=$true
            $e.Handled=$true
        }elseif($e.KeyCode-eq[Windows.Forms.Keys]::Enter-and$e.Control){
            Send-CodexConversationMessage
            $e.SuppressKeyPress=$true
            $e.Handled=$true
        }
    })
    $newTask.Add_Click({ $workflow = New-DefaultWorkflow '新工作任务' (Get-CurrentProjectId); $script:Workflows = @($script:Workflows) + $workflow; $script:CurrentWorkflow = $workflow; Save-Workflows; Refresh-WorkflowList })
    $deleteTask.Add_Click({ [void](Remove-SelectedWorkflowTask) })
    $exportConfig.Add_Click({ Show-ExportWorkflowConfiguration })
    $importConfig.Add_Click({ Show-ImportWorkflowConfiguration })

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = Get-TrayIcon
    $script:NotifyIcon.Text = $script:AppName
    $script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:TrayOpenItem = $script:TrayMenu.Items.Add('打开使驾')
    [void]$script:TrayMenu.Items.Add('-')
    $script:TrayExitItem = $script:TrayMenu.Items.Add('退出')
    $script:NotifyIcon.ContextMenuStrip = $script:TrayMenu
    $script:TrayOpenItem.Add_Click({ Restore-WorkflowManagerFromTray })
    $script:TrayExitItem.Add_Click({ Exit-WorkflowManager })
    $script:NotifyIcon.Add_MouseClick({
        param($sender, $eventArgs)
        $mouseEvent = @($sender) + @($eventArgs) + @($args) | Where-Object { $_ -is [Windows.Forms.MouseEventArgs] } | Select-Object -Last 1
        if ($null -ne $mouseEvent -and $mouseEvent.Button -eq [Windows.Forms.MouseButtons]::Left) { Restore-WorkflowManagerFromTray }
    })
    $script:NotifyIcon.Add_DoubleClick({ Restore-WorkflowManagerFromTray })
    $script:NotifyIcon.Add_BalloonTipClicked({ try { [void](Invoke-WorkflowBalloonAction) } catch { try { Write-WorkflowLog ('气泡点击动作失败：' + $_.Exception.Message) 'ERROR' } catch { } } })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        $closingEvent = @($sender) + @($eventArgs) + @($args) | Where-Object { $_ -is [Windows.Forms.FormClosingEventArgs] } | Select-Object -Last 1
        $closingForm = @($sender) + @($script:MainForm) | Where-Object { $_ -is [Windows.Forms.Form] } | Select-Object -First 1
        if ($null -eq $closingEvent -or $null -eq $closingForm) { return }
        $systemExit = $closingEvent.CloseReason -in @([Windows.Forms.CloseReason]::WindowsShutDown,[Windows.Forms.CloseReason]::TaskManagerClosing)
        if (-not $script:AllowExit -and -not $script:Exiting -and -not $systemExit) {
            $closingEvent.Cancel = $true
            $closingForm.Hide()
            Register-WorkflowTrayIcon
        }
    })
    $form.Add_FormClosed({ if (-not $script:Exiting) { Exit-WorkflowManager } })

    $script:SchedulerTimer = New-Object System.Windows.Forms.Timer
    $script:SchedulerTimer.Interval = 1000
    $script:SchedulerTimer.Add_Tick({ Invoke-SchedulerTick })
    $script:JobPollTimer = New-Object System.Windows.Forms.Timer
    $script:JobPollTimer.Interval = 200
    $script:JobPollTimer.Add_Tick({
        try { Poll-WorkflowJobs; if($null-ne$script:SessionManagerPanel-and$script:SessionManagerPanel.Visible){Refresh-SessionManagerView} }
        catch {
            try { Write-WorkflowLog ('运行任务状态刷新失败：' + $_.Exception.Message) 'ERROR' } catch { }
        }
    })
    $script:MemoryMaintenanceTimer = New-Object System.Windows.Forms.Timer
    $script:MemoryMaintenanceTimer.Interval = 60000
    $script:MemoryMaintenanceTimer.Add_Tick({
        try { Invoke-WorkflowMemoryMaintenance } catch { try { Write-WorkflowLog ('内存维护失败：' + $_.Exception.Message) 'WARN' } catch { } }
    })
    $script:ApiTimer = New-Object System.Windows.Forms.Timer
    $script:ApiTimer.Interval = 100
    $script:ApiTimer.Add_Tick({ Invoke-PendingWorkflowApiRequests; Invoke-PendingWorkflowWebRequests })
    Apply-UiTheme $form
    Apply-CodexConversationPalette
    Refresh-CodexConversationAttachmentPreview
    $script:RunningTaskLogBox.BackColor=[Drawing.Color]::FromArgb(15,23,42)
    $script:RunningTaskLogBox.ForeColor=[Drawing.Color]::FromArgb(226,232,240)
    $script:RunningTaskLogBox.Font=New-Object Drawing.Font('Consolas',9)
    Refresh-ProjectSelector
    [void](Start-WorkflowApiServer)
    [void](Start-WebApiServer)
    $script:ApiTimer.Start()
    $script:JobPollTimer.Start()
    $script:MemoryMaintenanceTimer.Start()
    $script:SchedulerTimer.Start()
    $form.Add_Shown({ Set-WorkflowWindowIcon $script:MainForm; Register-WorkflowTrayIcon -Refresh; Update-CodexConversationComposerHeight; [void](Resize-CodexConversationBubbles -Force); Write-WorkflowLog '使驾已启动。' })
    $applicationContext = New-Object System.Windows.Forms.ApplicationContext
    $script:ApplicationContext = $applicationContext
    $script:StartupTimer = New-Object Windows.Forms.Timer
    $script:StartupTimer.Interval = 50
    $script:StartupTimer.Add_Tick({
        $script:StartupTimer.Stop()
        $script:StartupTimer.Dispose()
        $script:StartupTimer = $null
        $form.Show()
    })
    $script:StartupTimer.Start()
    try {
        [System.Windows.Forms.Application]::Run($applicationContext)
    } finally {
        if ($script:ApplicationContext -eq $applicationContext) { $script:ApplicationContext = $null }
        $applicationContext.Dispose()
    }
}

function Invoke-WorkflowSelfTest {
    $testDirectory = Join-Path $env:TEMP ('PowerUI-WorkflowWorkerTest-' + $PID)
    $script:DataDirectory = $testDirectory
    $script:WorkflowPath = Join-Path $testDirectory 'workflows.json'
    $script:ProjectPath = Join-Path $testDirectory 'projects.json'
    $script:SettingsPath = Join-Path $testDirectory 'settings.json'
    $script:LogDirectory = Join-Path $testDirectory 'logs'
    $script:LogPath = Join-Path $script:LogDirectory 'selftest.log'
    $script:WorkflowAiDirectory = Join-Path $testDirectory 'workflow-ai'
    $script:EmbeddedWorkflowSkillPath = Join-Path $script:WorkflowAiDirectory 'skills\workflow-manager'
    $script:CodexSessionsDirectory = Join-Path $testDirectory 'sessions'
    $script:CodexSessionCache = @()
    $script:CodexSessionCacheAt = [datetime]::MinValue
    $script:CodexConversationSnapshots = @{}
    $script:CodexConversationProcesses = @{}
    $script:Projects = @()
    $script:RunningJobs = @{}
    $script:GlobalSettings = New-DefaultGlobalSettings
    Ensure-DataDirectories
    $inlineNode = New-WorkflowNode 'EnvWrite' '构建选项' 120 80 ([pscustomobject]@{ InlineEdit=$true; Items=@(
        [pscustomobject]@{Name='PackLinux';Label='打包 Linux';Value='false';ValueType='Boolean'},
        [pscustomobject]@{Name='PackGCU';Label='打包 GCU';Value='true';ValueType='Boolean'}
    ) })
    $inlineRows = @(Sync-InlineVariableNodeLayout $inlineNode)
    if($inlineRows.Count-ne2-or$inlineNode.Width-lt280-or$inlineNode.Height-lt136-or-not(Get-InlineVariableBooleanState $inlineRows[1].Value $inlineRows[1].ValueType).Value){throw 'Inline variable node layout or Boolean display state is invalid.'}
    $arrayCoordinateNode = New-WorkflowNode 'Cmd' '数组坐标回归' 120 80 ([pscustomobject]@{Command='echo test'})
    $arrayCoordinateNode.X = @(120); $arrayCoordinateNode.Y = @(80); $arrayCoordinateNode.Width = @(180); $arrayCoordinateNode.Height = @(72)
    $script:CurrentWorkflow = [pscustomobject]@{Nodes=@($arrayCoordinateNode)}
    if($null-eq(Get-NodeAt 140 90)-or$null-ne(Get-NodeAt 600 600)){throw 'Canvas hit testing did not normalize array coordinates.'}
    $script:CurrentWorkflow = $null
    $migrationProject=[pscustomobject]@{Id='main-branch-project';Name='主分支 功能与维护';UpdatedAt=(Get-Date).ToString('o')}
    $migrationStart=New-WorkflowNode 'Start' '开始' 20 20;$migrationCmd=New-WorkflowNode 'Cmd' '启动 Z.py' 240 20 ([pscustomobject]@{Command='python D:\200mergeBackup\Z.py';WorkingDirectory='D:\200mergeBackup';TimeoutSeconds='';OutputVar='build';FailOnError=$true});$migrationEnd=New-WorkflowNode 'End' '结束' 480 20
    $migrationWorkflow=[pscustomobject]@{Id='migration-workflow';Name='构建项目';ProjectId='main-branch-project';Enabled=$false;Nodes=@($migrationStart,$migrationCmd,$migrationEnd);Edges=@((New-WorkflowEdge $migrationStart.Id $migrationCmd.Id),(New-WorkflowEdge $migrationCmd.Id $migrationEnd.Id));UpdatedAt=(Get-Date).ToString('o')}
    $script:Projects=@($migrationProject);$script:Workflows=@($migrationWorkflow)
    if(-not(Upgrade-MainBranchBuildWorkflow)){throw 'Build workflow migration did not report its first change.'}
    $migrationOptions=@($migrationWorkflow.Nodes|Where-Object{$_.Type-eq'EnvWrite'-and$_.Name-eq'构建选项'})
    if($migrationOptions.Count-ne1-or[string]$migrationCmd.Config.Command-notlike'*--pack-linux {{var.PackLinux}}*'-or[string]$migrationCmd.Config.Command-notlike'*--pack-gcu {{var.PackGCU}}*'){throw 'Build workflow migration did not add inline options or command arguments.'}
    $migrationOptions[0].Config.Items[0].Value='true';Save-Workflows
    $secondMigrationChanged=[bool](Upgrade-MainBranchBuildWorkflow)
    $migrationOptionCount=@($migrationWorkflow.Nodes|Where-Object{$_.Name-eq'构建选项'}).Count
    if($secondMigrationChanged-or[string]$migrationOptions[0].Config.Items[0].Value-ne'true'-or$migrationOptionCount-ne1){throw 'Build workflow migration is not idempotent or reset a user option.'}
    $script:Projects=@();$script:Workflows=@()
    $fileTreeSelfRoot=Join-Path $testDirectory 'file-tree-selftest';$fileTreeNormal=Join-Path $fileTreeSelfRoot 'large';$fileTreeHeavy=Join-Path $fileTreeSelfRoot 'node_modules'
    [IO.Directory]::CreateDirectory($fileTreeNormal)|Out-Null;[IO.Directory]::CreateDirectory($fileTreeHeavy)|Out-Null
    foreach($fileIndex in 1..305){[IO.File]::WriteAllText((Join-Path $fileTreeNormal ('item-'+$fileIndex.ToString('000')+'.txt')),'x')}
    foreach($fileIndex in 1..105){[IO.File]::WriteAllText((Join-Path $fileTreeHeavy ('package-'+$fileIndex.ToString('000')+'.js')),'x')}
    $normalTreeResult=[WorkflowFileTreeLoader]::Enumerate($fileTreeNormal,300,'normal-test')
    $heavyTreeResult=[WorkflowFileTreeLoader]::Enumerate($fileTreeHeavy,(Get-CodexConversationFileTreeLimit $fileTreeHeavy),'heavy-test')
    if($normalTreeResult.Entries.Count-ne300-or-not$normalTreeResult.IsTruncated-or$normalTreeResult.RequestId-ne'normal-test'){throw 'Normal file-tree enumeration limit is invalid.'}
    if($heavyTreeResult.Limit-ne100-or$heavyTreeResult.Entries.Count-ne100-or-not$heavyTreeResult.IsTruncated){throw 'Heavy package directory file-tree limit is invalid.'}
    $textTreeFile=Join-Path $fileTreeSelfRoot 'sample.ps1';$binaryTreeFile=Join-Path $fileTreeSelfRoot 'sample.bin';$readmeTreeFile=Join-Path $fileTreeSelfRoot 'README'
    [IO.File]::WriteAllText($textTreeFile,'Write-Output ok');[IO.File]::WriteAllText($binaryTreeFile,'binary');[IO.File]::WriteAllText($readmeTreeFile,'readme')
    if(-not(Test-CodexConversationTextFile $textTreeFile)-or-not(Test-CodexConversationTextFile $readmeTreeFile)-or(Test-CodexConversationTextFile $binaryTreeFile)){throw 'File-tree text document detection is invalid.'}
    $script:GlobalSettings.DocumentEditorPath=Join-Path $env:WINDIR 'System32\notepad.exe'
    $textLaunch=Get-CodexConversationFileLaunchSpec $textTreeFile;$binaryLaunch=Get-CodexConversationFileLaunchSpec $binaryTreeFile;$directoryLaunch=Get-CodexConversationFileLaunchSpec $fileTreeSelfRoot
    if($textLaunch.Kind-ne'TextFile'-or[IO.Path]::GetFileName($textLaunch.FilePath)-ne'notepad.exe'-or[string]$textLaunch.Arguments[0]-ne$textTreeFile){throw 'Text file-tree launch specification is invalid.'}
    if($binaryLaunch.Kind-ne'DefaultFile'-or[string]$binaryLaunch.FilePath-ne$binaryTreeFile-or$directoryLaunch.Kind-ne'Directory'-or[string]$directoryLaunch.FilePath-ne'explorer.exe'){throw 'Default file or directory launch specification is invalid.'}
    $normalizedInvalidPalette=Normalize-GlobalSettings ([pscustomobject]@{ConversationUserBubbleColor='invalid-color'})
    if([string]$normalizedInvalidPalette.ConversationUserBubbleColor-ne'#DBEAFE'){throw 'Invalid conversation color did not fall back to the default palette.'}
    $nestedProject=[pscustomobject]@{Id='nested-project';Name='Nested project';DefaultWorkingDirectory='C:\Nested';CodexSessionId='nested-session';UpdatedAt=''}
    $flatProject=[pscustomobject]@{Id='flat-project';Name='Flat project';DefaultWorkingDirectory='C:\Flat';CodexSessionId='';CodexModel='test-model';UpdatedAt=''}
    $projectCompatibilityFixture=[pscustomobject]@{Projects=@((,$nestedProject),$flatProject,'ignored-project-value',42)}
    Write-JsonFileAtomic $script:ProjectPath $projectCompatibilityFixture
    $compatibleProjects=@(Load-Projects)
    if($compatibleProjects.Count-ne2-or@($compatibleProjects|Where-Object{[string]$_.Id-eq'nested-project'}).Count-ne1-or@($compatibleProjects|Where-Object{[string]$_.Id-eq'flat-project'-and[string]$_.CodexModel-eq'test-model'}).Count-ne1){throw 'Wrapped or nested project compatibility loading failed.'}
    $dictionaryProject=Normalize-Project ([ordered]@{name='Dictionary project';defaultWorkingDirectory='C:\Dictionary';codexSessionId='dictionary-session'})
    if($null-eq$dictionaryProject-or[string]$dictionaryProject.Name-ne'Dictionary project'-or[string]$dictionaryProject.DefaultWorkingDirectory-ne'C:\Dictionary'-or[string]$dictionaryProject.CodexModel-ne''){throw 'Dictionary project normalization failed.'}
    $multiSessionProject=New-Project -Name 'Multi session project' -DefaultWorkingDirectory 'C:\Multi' -CodexSessions @([pscustomobject]@{sessionId='main-session';codexModel='gpt-main';description='主问题处理'},[pscustomobject]@{sessionId='question-session';codexModel='gpt-question';description='临时提问'})
    $multiSessions=@(Get-ProjectCodexSessions $multiSessionProject)
    if($multiSessions.Count-ne2-or[string]$multiSessionProject.CodexSessionId-ne'main-session'-or[string]$multiSessionProject.CodexModel-ne'gpt-main'-or[string]$multiSessions[1].Description-ne'临时提问'){throw 'Multi-session project normalization or primary-session compatibility failed.'}
    Set-ProjectCodexSessions $multiSessionProject @($multiSessions[1],$multiSessions[0],$multiSessions[1])
    $reorderedSessions=@(Get-ProjectCodexSessions $multiSessionProject)
    if($reorderedSessions.Count-ne2-or[string]$multiSessionProject.CodexSessionId-ne'question-session'-or[string]$reorderedSessions[0].Description-ne'临时提问'){throw 'Multi-session primary ordering or duplicate removal failed.'}
    if((Get-UiConfigValue @([pscustomobject]@{Name='array item'}) 'Properties' 'safe-default')-ne'safe-default'-or(Test-UiConfigValue @('array item') 'Properties')){throw 'Array configuration compatibility access failed.'}
    Remove-Item -LiteralPath $script:ProjectPath -Force
    $caretBox=New-Object Windows.Forms.TextBox
    try{
        $caretBox.Multiline=$true;$caretBox.Text="first line`r`nmiddle line`r`nlast line";$caretBox.CreateControl()
        $lastLinePosition=$caretBox.Text.LastIndexOf('last line')+3;$caretBox.SelectionStart=$lastLinePosition;$caretBox.SelectionLength=0
        if(-not(Move-CodexConversationInputCaretAtBoundary $caretBox ([Windows.Forms.Keys]::Down))-or$caretBox.SelectionStart-ne$caretBox.TextLength){throw 'Conversation input Down-arrow boundary behavior failed.'}
        $caretBox.SelectionStart=4;$caretBox.SelectionLength=0
        if(-not(Move-CodexConversationInputCaretAtBoundary $caretBox ([Windows.Forms.Keys]::Up))-or$caretBox.SelectionStart-ne0){throw 'Conversation input Up-arrow boundary behavior failed.'}
        $middlePosition=$caretBox.Text.IndexOf('middle line')+3;$caretBox.SelectionStart=$middlePosition;$caretBox.SelectionLength=0
        if((Move-CodexConversationInputCaretAtBoundary $caretBox ([Windows.Forms.Keys]::Down))-or$caretBox.SelectionStart-ne$middlePosition){throw 'Conversation input middle-line arrow behavior was overridden.'}
        $caretBox.SelectionStart=$lastLinePosition;$caretBox.SelectionLength=2
        if(Move-CodexConversationInputCaretAtBoundary $caretBox ([Windows.Forms.Keys]::Down)){throw 'Conversation input selected-text arrow behavior was overridden.'}
    }finally{$caretBox.Dispose()}
    $workerEventPath=Join-Path $testDirectory 'worker-event-limit.jsonl'
    $eventBuilder=New-Object Text.StringBuilder
    foreach($eventIndex in 1..600){[void]$eventBuilder.AppendLine(('{{"Kind":"Log","Message":"line-{0}"}}'-f$eventIndex))}
    [IO.File]::WriteAllText($workerEventPath,$eventBuilder.ToString(),(New-Object Text.UTF8Encoding($false)))
    $eventWorker=[pscustomobject]@{OutputPath=$workerEventPath;ReadOffset=[long]0}
    $firstEventBatch=@(Read-WorkerEventLines $eventWorker)
    if($firstEventBatch.Count-le0-or$firstEventBatch.Count-gt240-or[long]$eventWorker.ReadOffset-ge(Get-Item -LiteralPath $workerEventPath).Length){throw 'Worker event reader did not limit its first high-volume batch.'}
    $allEventLines=New-Object System.Collections.Generic.List[string]
    $allEventLines.AddRange([string[]]$firstEventBatch)
    $eventReadGuard=0
    while(-not(Test-WorkerEventOutputDrained $eventWorker)-and$eventReadGuard-lt10){$nextEventBatch=@(Read-WorkerEventLines $eventWorker);$allEventLines.AddRange([string[]]$nextEventBatch);$eventReadGuard++}
    if($allEventLines.Count-ne600-or-not(Test-WorkerEventOutputDrained $eventWorker)){throw 'Worker event reader did not drain all throttled log batches.'}
    Remove-Item -LiteralPath $workerEventPath -Force
    $previousRunningTaskDisplayedId=$script:RunningTaskDisplayedId;$previousRunningTaskDisplayedLogCount=$script:RunningTaskDisplayedLogCount;$previousRunningTaskLogNeedsReset=$script:RunningTaskLogNeedsReset
    try{
        $logLimitRecord=[pscustomobject]@{WorkflowId='log-limit-test';Logs=(New-Object System.Collections.ArrayList)}
        $script:RunningTaskDisplayedId='log-limit-test';$script:RunningTaskDisplayedLogCount=0;$script:RunningTaskLogNeedsReset=$false
        foreach($logIndex in 1..3001){Add-RunningTaskLog $logLimitRecord ('line-'+$logIndex)}
        if($logLimitRecord.Logs.Count-gt3000-or-not$script:RunningTaskLogNeedsReset){throw 'Running-task in-memory log limit or view reset flag is invalid.'}
    }finally{$script:RunningTaskDisplayedId=$previousRunningTaskDisplayedId;$script:RunningTaskDisplayedLogCount=$previousRunningTaskDisplayedLogCount;$script:RunningTaskLogNeedsReset=$previousRunningTaskLogNeedsReset}
    function Invoke-SelfTestWorkflow {
        param($TestWorkflow, [int]$TimeoutSeconds = 30)
        $testWorker = Start-WorkerProcess $TestWorkflow
        $testDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $testWorker.Process.HasExited -and (Get-Date) -lt $testDeadline) { Start-Sleep -Milliseconds 100 }
        if (-not $testWorker.Process.HasExited) { Stop-Process -Id $testWorker.Process.Id -Force -ErrorAction SilentlyContinue; throw "Workflow timed out: $($TestWorkflow.Name)" }
        $testLines = @()
        if (Test-Path -LiteralPath $testWorker.OutputPath) { $testLines = @((Read-TextFileWithRetry $testWorker.OutputPath) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
        $testError = if (Test-Path -LiteralPath $testWorker.ErrorPath) { Read-TextFileWithRetry $testWorker.ErrorPath } else { '' }
        foreach ($path in @($testWorker.InputPath,$testWorker.OutputPath,$testWorker.ErrorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        $testEvents = @($testLines | ForEach-Object { [string]$_ | ConvertFrom-Json })
        if (@($testEvents | Where-Object Kind -eq 'Done').Count -ne 1) { throw "Workflow failed: $($TestWorkflow.Name); events=$($testEvents | ConvertTo-Json -Depth 8 -Compress); error=$testError" }
        return @($testEvents)
    }
    $start = New-WorkflowNode 'Start' '开始' 20 20
    $write = New-WorkflowNode 'EnvWrite' '批量定义变量' 220 20 ([pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'GREETING'; Value = 'hello' }, [pscustomobject]@{ COUNT = '2' }) })
    $cmd = New-WorkflowNode 'Cmd' '测试 CMD' 460 20 ([pscustomobject]@{ Command = 'echo {{var.GREETING}}-{{var.COUNT}}'; WorkingDirectory = ''; TimeoutSeconds = 15; OutputVar = 'cmdResult'; FailOnError = $true })
    $balloon = New-WorkflowNode 'Balloon' '测试提醒' 700 20 ([pscustomobject]@{ Title = 'Self test'; Message = '{{var.cmdResult.StdOut}} workflow'; ClickAction='OpenUrl'; ClickTarget='https://example.com/{{var.COUNT}}' })
    $end = New-WorkflowNode 'End' '结束' 940 20
    $workflow = [pscustomobject]@{ Id = 'self-test'; Name = 'Self test'; Enabled = $false; IntervalMinutes = 60; NextRunUtc = (Get-Date).ToUniversalTime().ToString('o'); Nodes = @($start,$write,$cmd,$balloon,$end); Edges = @((New-WorkflowEdge $start.Id $write.Id),(New-WorkflowEdge $write.Id $cmd.Id),(New-WorkflowEdge $cmd.Id $balloon.Id),(New-WorkflowEdge $balloon.Id $end.Id)); UpdatedAt = (Get-Date).ToString('o') }
    $worker = Start-WorkerProcess $workflow
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $worker.Process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not $worker.Process.HasExited) { Stop-Process -Id $worker.Process.Id -Force -ErrorAction SilentlyContinue; throw 'Worker self-test timed out.' }
    $lines = @()
    if (Test-Path -LiteralPath $worker.OutputPath) { $lines = @((Read-TextFileWithRetry $worker.OutputPath) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    $workerError = if (Test-Path -LiteralPath $worker.ErrorPath) { Read-TextFileWithRetry $worker.ErrorPath } else { '' }
    foreach ($path in @($worker.InputPath, $worker.OutputPath, $worker.ErrorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $events = @($lines | ForEach-Object { [string]$_ | ConvertFrom-Json })
    if (@($events | Where-Object Kind -eq 'Done').Count -ne 1) { throw "Worker did not emit Done. Events=$($events | ConvertTo-Json -Depth 8 -Compress); Error=$workerError" }
    $balloonEvent = @($events | Where-Object Kind -eq 'Balloon' | Select-Object -First 1)
    if ($balloonEvent.Count -ne 1 -or $balloonEvent[0].Message -ne 'hello-2 workflow' -or [string]$balloonEvent[0].Data.ClickAction -ne 'OpenUrl' -or [string]$balloonEvent[0].Data.ClickTarget -ne 'https://example.com/2') { throw ('Batch environment, CMD output template, or clickable balloon node failed: ' + ($balloonEvent | ConvertTo-Json -Depth 8 -Compress)) }
    $legacyBalloonWorkflow=Normalize-Workflow ([pscustomobject]@{Id='legacy-balloon';Name='Legacy balloon';Enabled=$false;IntervalMinutes=60;NextRunUtc=(Get-Date).ToUniversalTime().ToString('o');Nodes=@((New-WorkflowNode 'Start' '开始' 0 0),(New-WorkflowNode 'Balloon' '旧提醒' 200 0 ([pscustomobject]@{Title='旧提醒';Message='完成'})),(New-WorkflowNode 'End' '结束' 400 0));Edges=@()})
    $legacyBalloon=@($legacyBalloonWorkflow.Nodes|Where-Object { [string]$_.Type -eq 'Balloon' }|Select-Object -First 1)[0]
    if([string]$legacyBalloon.Config.ClickAction-ne'None'-or[string]$legacyBalloon.Config.ClickTarget-ne''){throw 'Legacy balloon click configuration was not normalized.'}
    $urlLaunch=Get-BalloonLaunchSpec 'OpenUrl' 'https://example.com/path';if($null-eq$urlLaunch-or$urlLaunch.FilePath-ne'https://example.com/path'){throw 'Balloon URL launch specification is invalid.'}
    $pathLaunch=Get-BalloonLaunchSpec 'OpenPath' $testDirectory;if($null-eq$pathLaunch-or$pathLaunch.FilePath-ne$testDirectory){throw 'Balloon path launch specification is invalid.'}
    $unsafeUrlRejected=$false;try{[void](Get-BalloonLaunchSpec 'OpenUrl' 'file:///C:/Windows/notepad.exe')}catch{$unsafeUrlRejected=$true};if(-not$unsafeUrlRejected){throw 'Balloon URL validation accepted an unsafe scheme.'}
    if (@($events | Where-Object { $_.Kind -eq 'Log' -and $_.Message -like '*CMD 退出码 0*' }).Count -ne 1) { throw 'CMD node did not complete successfully.' }

    $encodedUrl='https://play.xfvod.pro:8088/temp/2607/%E9%AD%94%E5%85%BD07.mp4'
    $previousCmdPercentTest=[Environment]::GetEnvironmentVariable('POWERUI_CMD_PERCENT_TEST','Process')
    [Environment]::SetEnvironmentVariable('POWERUI_CMD_PERCENT_TEST','env-expanded','Process')
    try {
        $percentStart=New-WorkflowNode 'Start' '开始' 20 20
        $percentWrite=New-WorkflowNode 'EnvWrite' '写入 URL' 220 20 ([pscustomobject]@{Items=@(
            [pscustomobject]@{Name='URL';Value=$encodedUrl},
            [pscustomobject]@{Name='PERCENT';Value='100%'}
        )})
        $percentCommand='echo VARIABLE={{var.URL}} & echo PERCENT={{var.PERCENT}} & echo STATIC_ENV=%POWERUI_CMD_PERCENT_TEST% & echo STATIC_URL='+$encodedUrl
        $percentCmd=New-WorkflowNode 'Cmd' 'CMD 百分号编码回归' 460 20 ([pscustomobject]@{Command=$percentCommand;WorkingDirectory='';TimeoutSeconds=15;OutputVar='percentResult';FailOnError=$true})
        $percentEnd=New-WorkflowNode 'End' '结束' 700 20
        $percentWorkflow=[pscustomobject]@{Id='cmd-percent-url-test';Name='CMD percent URL test';Enabled=$false;Nodes=@($percentStart,$percentWrite,$percentCmd,$percentEnd);Edges=@((New-WorkflowEdge $percentStart.Id $percentWrite.Id),(New-WorkflowEdge $percentWrite.Id $percentCmd.Id),(New-WorkflowEdge $percentCmd.Id $percentEnd.Id))}
        $percentEvents=@(Invoke-SelfTestWorkflow $percentWorkflow)
        $percentOutput=@($percentEvents|Where-Object Kind -eq 'CommandOutput'|ForEach-Object{([string]$_.Message).TrimEnd()})
        foreach($expectedOutput in @(
            ('VARIABLE='+$encodedUrl),
            'PERCENT=100%',
            'STATIC_ENV=env-expanded',
            ('STATIC_URL='+$encodedUrl)
        )){
            if($percentOutput-notcontains$expectedOutput){throw ('CMD batch percent/URL protection failed: expected='+$expectedOutput+'; output='+($percentOutput-join' | '))}
        }
    } finally {
        [Environment]::SetEnvironmentVariable('POWERUI_CMD_PERCENT_TEST',$previousCmdPercentTest,'Process')
    }

    $streamStart = New-WorkflowNode 'Start' '开始' 20 20
    $streamCommand = 'powershell.exe -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; [Console]::WriteLine(''first-line''); [Console]::Out.Flush(); Start-Sleep -Seconds 4; [Console]::WriteLine(''second-line'')"'
    $streamCmd = New-WorkflowNode 'Cmd' '实时输出 CMD' 260 20 ([pscustomobject]@{ Command=$streamCommand; WorkingDirectory=$testDirectory; TimeoutSeconds=''; OutputVar='streamResult'; FailOnError=$true })
    $streamEnd = New-WorkflowNode 'End' '结束' 520 20
    $streamWorkflow = [pscustomobject]@{ Id='streaming-self-test'; Name='Streaming CMD self test'; Enabled=$false; IntervalMinutes=60; NextRunUtc=(Get-Date).ToUniversalTime().ToString('o'); Nodes=@($streamStart,$streamCmd,$streamEnd); Edges=@((New-WorkflowEdge $streamStart.Id $streamCmd.Id),(New-WorkflowEdge $streamCmd.Id $streamEnd.Id)); UpdatedAt=(Get-Date).ToString('o') }
    $script:Workflows = @($streamWorkflow)
    Start-WorkflowJob $streamWorkflow -Manual
    $streamRecord = $script:RunningJobs[[string]$streamWorkflow.Id]
    if ($null -eq $streamRecord) { throw 'Streaming CMD task did not enter the running task collection.' }
    $firstLineDeadline = (Get-Date).AddSeconds(8)
    $firstLineObserved = $false
    while ((Get-Date) -lt $firstLineDeadline) {
        Poll-WorkflowJobs
        $firstLineObserved = @($streamRecord.Logs | Where-Object { $_.Kind -eq 'CommandOutput' -and $_.Message -like '*first-line*' }).Count -gt 0
        if ($firstLineObserved) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not $firstLineObserved) { throw 'CMD first output line was not delivered while the task was running.' }
    if ($streamRecord.Worker.Process.HasExited) { throw 'No-timeout CMD output was only visible after the worker exited.' }
    if ($streamRecord.CurrentNodeType -ne 'Cmd' -or $streamRecord.CurrentNodeName -ne '实时输出 CMD') { throw 'Running task did not expose the active CMD node.' }
    if ([int]$streamRecord.ActiveProcessId -le 0) { throw 'Running task did not expose the active CMD process ID.' }
    if (@($streamRecord.Logs | Where-Object { $_.Kind -eq 'CommandOutput' -and $_.Message -like '*second-line*' }).Count -ne 0) { throw 'Streaming CMD test observed the delayed line too early.' }
    $streamCompleteDeadline = (Get-Date).AddSeconds(12)
    while ($script:RunningJobs.ContainsKey([string]$streamWorkflow.Id) -and (Get-Date) -lt $streamCompleteDeadline) { Poll-WorkflowJobs; Start-Sleep -Milliseconds 50 }
    if ($script:RunningJobs.ContainsKey([string]$streamWorkflow.Id)) { [void](Stop-WorkflowJob ([string]$streamWorkflow.Id) -Silent); throw 'Streaming CMD task did not complete.' }
    if (@($streamRecord.Logs | Where-Object { $_.Kind -eq 'CommandOutput' -and $_.Message -like '*second-line*' }).Count -ne 1 -or -not $streamRecord.DoneEvent) { throw 'No-timeout CMD task did not wait for natural completion and deliver its final output.' }
    if (@($streamRecord.Logs | Where-Object { $_.Message -like '*未配置超时，将持续等待 CMD 结束*' }).Count -ne 1) { throw 'No-timeout CMD task did not report unlimited-wait mode.' }

    $stopStart = New-WorkflowNode 'Start' '开始' 20 20
    $stopCommand = 'powershell.exe -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; [Console]::WriteLine(''CHILD_PID='' + $PID); [Console]::Out.Flush(); Start-Sleep -Seconds 60"'
    $stopCmd = New-WorkflowNode 'Cmd' '长时间 CMD' 260 20 ([pscustomobject]@{ Command=$stopCommand; WorkingDirectory=$testDirectory; TimeoutSeconds=''; OutputVar='stopResult'; FailOnError=$true })
    $stopEnd = New-WorkflowNode 'End' '结束' 520 20
    $stopWorkflow = [pscustomobject]@{ Id='stop-self-test'; Name='Stop process tree self test'; Enabled=$false; IntervalMinutes=60; NextRunUtc=(Get-Date).ToUniversalTime().ToString('o'); Nodes=@($stopStart,$stopCmd,$stopEnd); Edges=@((New-WorkflowEdge $stopStart.Id $stopCmd.Id),(New-WorkflowEdge $stopCmd.Id $stopEnd.Id)); UpdatedAt=(Get-Date).ToString('o') }
    $script:Workflows = @($stopWorkflow)
    Start-WorkflowJob $stopWorkflow -Manual
    $stopRecord = $script:RunningJobs[[string]$stopWorkflow.Id]
    if ($null -eq $stopRecord) { throw 'Stop task did not enter the running task collection.' }
    $stopReadyDeadline = (Get-Date).AddSeconds(10)
    $childProcessId = 0
    while ((Get-Date) -lt $stopReadyDeadline) {
        Poll-WorkflowJobs
        $childLine = @($stopRecord.Logs | Where-Object { $_.Kind -eq 'CommandOutput' -and $_.Message -match 'CHILD_PID=([0-9]+)' } | Select-Object -First 1)
        if ($childLine.Count -eq 1) { $childProcessId = [int][regex]::Match([string]$childLine[0].Message, 'CHILD_PID=([0-9]+)').Groups[1].Value }
        if ([int]$stopRecord.ActiveProcessId -gt 0 -and $childProcessId -gt 0) { break }
        Start-Sleep -Milliseconds 50
    }
    $workerProcessId = [int]$stopRecord.Worker.Process.Id
    $cmdProcessId = [int]$stopRecord.ActiveProcessId
    if ($workerProcessId -le 0 -or $cmdProcessId -le 0 -or $childProcessId -le 0) { throw 'Stop task did not report the worker, CMD, and child process IDs.' }
    if (-not (Stop-WorkflowJob ([string]$stopWorkflow.Id) -Silent)) { throw 'Stop task request was rejected.' }
    $stopCompleteDeadline = (Get-Date).AddSeconds(10)
    while ($script:RunningJobs.ContainsKey([string]$stopWorkflow.Id) -and (Get-Date) -lt $stopCompleteDeadline) { Poll-WorkflowJobs; Start-Sleep -Milliseconds 50 }
    if ($script:RunningJobs.ContainsKey([string]$stopWorkflow.Id)) { throw 'Stopped task remained in the running task collection.' }
    foreach ($stoppedProcessId in @($workerProcessId,$cmdProcessId,$childProcessId)) {
        if ($null -ne (Get-Process -Id $stoppedProcessId -ErrorAction SilentlyContinue)) { throw "Stopped process is still alive: $stoppedProcessId" }
    }
    if ($stopRecord.Status -ne '已停止' -or @($stopRecord.Logs | Where-Object { $_.Kind -eq 'Stopped' -and $_.Message -eq '任务已停止。' }).Count -ne 1) { throw 'Stopped task status or lifecycle log is invalid.' }

    $restartStart=New-WorkflowNode 'Start' '开始' 20 20
    $restartCmd=New-WorkflowNode 'Cmd' '短任务' 260 20 ([pscustomobject]@{Command='powershell.exe -NoProfile -Command "Start-Sleep -Milliseconds 1200; Write-Output restarted"';WorkingDirectory=$testDirectory;TimeoutSeconds='';OutputVar='restartResult';FailOnError=$true})
    $restartEnd=New-WorkflowNode 'End' '结束' 520 20
    $restartWorkflow=[pscustomobject]@{Id='restart-self-test';Name='Restart self test';Enabled=$false;IntervalMinutes=60;NextRunUtc=(Get-Date).ToUniversalTime().ToString('o');Nodes=@($restartStart,$restartCmd,$restartEnd);Edges=@((New-WorkflowEdge $restartStart.Id $restartCmd.Id),(New-WorkflowEdge $restartCmd.Id $restartEnd.Id));UpdatedAt=(Get-Date).ToString('o')}
    $script:Workflows=@($restartWorkflow);Start-WorkflowJob $restartWorkflow -Manual
    $firstRestartRecord=$script:RunningJobs[[string]$restartWorkflow.Id];$firstRestartPid=[int]$firstRestartRecord.Worker.Process.Id
    if(-not(Restart-WorkflowJob ([string]$restartWorkflow.Id))){throw 'Restart request was rejected.'}
    if(-not$script:PendingWorkflowRestarts.ContainsKey([string]$restartWorkflow.Id)){throw 'Restart request was not queued while the task was running.'}
    $restartDeadline=(Get-Date).AddSeconds(12);$secondRestartPid=0
    while((Get-Date)-lt$restartDeadline){Poll-WorkflowJobs;if($script:RunningJobs.ContainsKey([string]$restartWorkflow.Id)){$candidate=[int]$script:RunningJobs[[string]$restartWorkflow.Id].Worker.Process.Id;if($candidate-ne$firstRestartPid){$secondRestartPid=$candidate;break}};Start-Sleep -Milliseconds 50}
    if($secondRestartPid-le0-or$script:PendingWorkflowRestarts.ContainsKey([string]$restartWorkflow.Id)){throw 'Restart did not wait for cleanup and launch exactly one new worker.'}
    $restartCompleteDeadline=(Get-Date).AddSeconds(12);while($script:RunningJobs.ContainsKey([string]$restartWorkflow.Id)-and(Get-Date)-lt$restartCompleteDeadline){Poll-WorkflowJobs;Start-Sleep -Milliseconds 50}
    if($script:RunningJobs.ContainsKey([string]$restartWorkflow.Id)){[void](Stop-WorkflowJob ([string]$restartWorkflow.Id) -Silent);throw 'Restarted task did not finish.'}

    $fakeVSCodePath = Join-Path $testDirectory 'fake-code.exe'
    [IO.File]::WriteAllBytes($fakeVSCodePath,[byte[]](77,90))
    $vscodeLaunch = Get-VSCodeLaunchSpec $testDirectory $fakeVSCodePath
    if($null-eq$vscodeLaunch-or[string]::IsNullOrWhiteSpace([string]$vscodeLaunch.FilePath)-or$vscodeLaunch.WorkingDirectory-ne$testDirectory-or@($vscodeLaunch.Arguments).Count-ne1-or[string]$vscodeLaunch.Arguments[0]-ne'.'){throw 'VS Code launch specification does not execute code . in the project directory.'}

    $fakeCodexDirectory = Join-Path $testDirectory 'Codex working directory'
    $fakeCodexPath = Join-Path $testDirectory 'fake codex.exe'
    $fakeCodexSourcePath = Join-Path $testDirectory 'FakeCodex.cs'
    [IO.Directory]::CreateDirectory($fakeCodexDirectory) | Out-Null
    $fakeCodexSource = @'
using System;
using System.IO;
using System.Text;

public static class FakeCodex
{
    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.WriteLine("ARGS=" + args.Length);
        for (int i = 0; i < args.Length; i++)
        {
            Console.WriteLine("ARG" + i + "=" + args[i]);
            if ((args[i] == "-o" || args[i] == "--output-last-message") && i + 1 < args.Length)
            {
                File.WriteAllText(args[i + 1], "Fake Codex final response", new UTF8Encoding(false));
            }
        }
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"019fffff-project-created-session\"}");
        Console.WriteLine("CWD=" + Environment.CurrentDirectory);
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($fakeCodexSourcePath, $fakeCodexSource, (New-Object Text.UTF8Encoding($false)))
    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $cscPath = @($cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($cscPath.Count -ne 1) { throw 'C# compiler is unavailable for the Codex node self-test.' }
    $compileOutput = @(& $cscPath[0] '/nologo' '/target:exe' (('/out:' + $fakeCodexPath)) $fakeCodexSourcePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeCodexPath)) { throw "Fake Codex compilation failed: $($compileOutput -join [Environment]::NewLine)" }
    $previousCodexTestExe = [Environment]::GetEnvironmentVariable('POWERUI_CODEX_TEST_EXE', 'Process')
    $previousCodexTestDirectory = [Environment]::GetEnvironmentVariable('POWERUI_CODEX_TEST_DIR', 'Process')
    [Environment]::SetEnvironmentVariable('POWERUI_CODEX_TEST_EXE', $fakeCodexPath, 'Process')
    [Environment]::SetEnvironmentVariable('POWERUI_CODEX_TEST_DIR', $fakeCodexDirectory, 'Process')
    $previousGlobalCodexPath = [string]$script:GlobalSettings.CodexPath
    $script:GlobalSettings.CodexPath = '%POWERUI_CODEX_TEST_EXE%'
    try {
        $codexStart = New-WorkflowNode 'Start' '开始' 20 20
        $codexInput = New-WorkflowNode 'EnvWrite' '准备实时数据' 220 20 ([pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'INPUT'; Value = 'hello codex' }) })
        $codexCall = New-WorkflowNode 'Codex' '测试新建 Codex 会话' 440 20 ([pscustomobject]@{ CodexPath = '%POWERUI_CODEX_TEST_EXE%'; WorkingDirectory = '%POWERUI_CODEX_TEST_DIR%'; SessionId = ''; Model = 'gpt-5.4 test'; Request = 'Review "{{var.INPUT}}".'; LiveData = "value={{var.INPUT}}`r`nsecond=line with spaces"; TimeoutSeconds = 15; OutputVar = 'codexResult'; FailOnError = $true })
        $codexOutput = New-WorkflowNode 'Balloon' '读取 Codex 输出' 680 20 ([pscustomobject]@{ Title = 'Codex test'; Message = 'mode={{var.codexResult.InvocationMode}};session={{var.codexResult.SessionId}};{{var.codexResult.StdOut}}' })
        $codexEnd = New-WorkflowNode 'End' '结束' 900 20
        $codexWorkflow = [pscustomobject]@{ Id = 'codex-test'; Name = 'Codex node test'; Enabled = $false; Nodes = @($codexStart,$codexInput,$codexCall,$codexOutput,$codexEnd); Edges = @((New-WorkflowEdge $codexStart.Id $codexInput.Id),(New-WorkflowEdge $codexInput.Id $codexCall.Id),(New-WorkflowEdge $codexCall.Id $codexOutput.Id),(New-WorkflowEdge $codexOutput.Id $codexEnd.Id)) }
        $codexEvents = @(Invoke-SelfTestWorkflow $codexWorkflow)
        $codexBalloon = @($codexEvents | Where-Object Kind -eq 'Balloon' | Select-Object -First 1)
        if ($codexBalloon.Count -ne 1) { throw 'Codex output variable was not available to the next node.' }
        $codexText = [string]$codexBalloon[0].Message
        foreach ($expectedText in @('mode=New;session=;','ARGS=8','ARG0=-C',("ARG1=" + $fakeCodexDirectory),'ARG2=exec','ARG3=--yolo','ARG4=--skip-git-repo-check','ARG5=--model','ARG6=gpt-5.4 test','ARG7=Review "hello codex".','附带的实时数据：','value=hello codex','second=line with spaces',("CWD=" + $fakeCodexDirectory))) {
            if ($codexText.IndexOf($expectedText, [StringComparison]::Ordinal) -lt 0) { throw "Codex argument or template expansion failed: $expectedText; output=$codexText" }
        }
        if (@($codexEvents | Where-Object { $_.Kind -eq 'Log' -and $_.Message -like '*Codex 退出码 0*' }).Count -ne 1) { throw 'Codex node did not complete successfully.' }
        if (@($codexEvents | Where-Object { $_.Kind -eq 'CodexStarted' -and [int]$_.Data.ProcessId -gt 0 }).Count -ne 1) { throw 'Codex node did not report its live process and session state.' }

        $resumeStart = New-WorkflowNode 'Start' '开始' 20 20
        $resumeInput = New-WorkflowNode 'EnvWrite' '准备会话 ID' 220 20 ([pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'SESSION_ID'; Value = 'session "with spaces"' }) })
        $resumeCall = New-WorkflowNode 'Codex' '测试恢复 Codex 会话' 440 20 ([pscustomobject]@{ CodexPath = '%POWERUI_CODEX_TEST_EXE%'; WorkingDirectory = 'Z:\PowerUI\MissingResumeDirectory'; SessionId = '{{var.SESSION_ID}}'; Model = 'gpt-5.4 test'; Request = 'Continue {{var.INPUT}}'; LiveData = ''; TimeoutSeconds = 15; OutputVar = 'resumedCodex'; FailOnError = $true })
        $resumeOutput = New-WorkflowNode 'Balloon' '读取恢复结果' 680 20 ([pscustomobject]@{ Title = 'Codex resume test'; Message = 'mode={{var.resumedCodex.InvocationMode}};session={{var.resumedCodex.SessionId}};{{var.resumedCodex.StdOut}}' })
        $resumeEnd = New-WorkflowNode 'End' '结束' 900 20
        $resumeWorkflow = [pscustomobject]@{ Id = 'codex-resume-test'; Name = 'Codex resume node test'; Enabled = $false; Nodes = @($resumeStart,$codexInput,$resumeInput,$resumeCall,$resumeOutput,$resumeEnd); Edges = @((New-WorkflowEdge $resumeStart.Id $codexInput.Id),(New-WorkflowEdge $codexInput.Id $resumeInput.Id),(New-WorkflowEdge $resumeInput.Id $resumeCall.Id),(New-WorkflowEdge $resumeCall.Id $resumeOutput.Id),(New-WorkflowEdge $resumeOutput.Id $resumeEnd.Id)) }
        $resumeEvents = @(Invoke-SelfTestWorkflow $resumeWorkflow)
        $resumeBalloon = @($resumeEvents | Where-Object Kind -eq 'Balloon' | Select-Object -First 1)
        if ($resumeBalloon.Count -ne 1) { throw 'Resumed Codex output variable was not available to the next node.' }
        $resumeText = [string]$resumeBalloon[0].Message
        foreach ($expectedText in @('mode=Resume;session=session "with spaces";','ARGS=8','ARG0=exec','ARG1=--yolo','ARG2=--skip-git-repo-check','ARG3=--model','ARG4=gpt-5.4 test','ARG5=resume','ARG6=session "with spaces"','ARG7=Continue hello codex')) {
            if ($resumeText.IndexOf($expectedText, [StringComparison]::Ordinal) -lt 0) { throw "Codex resume argument or template expansion failed: $expectedText; output=$resumeText" }
        }
        if ($resumeText.IndexOf('ARG0=-C', [StringComparison]::Ordinal) -ge 0) { throw "Codex resume unexpectedly used -C: $resumeText" }

        $pythonStart = New-WorkflowNode 'Start' '开始' 20 20
        $pythonCall = New-WorkflowNode 'Python' '测试 Python 实时执行' 240 20 ([pscustomobject]@{ Mode='Inline'; Script="print('executed by the configured interpreter')"; InterpreterPath=$fakeCodexPath; WorkingDirectory=$fakeCodexDirectory; Arguments='alpha "two words"'; TimeoutSeconds=''; OutputVar='pythonResult'; FailOnError=$true })
        $pythonOutput = New-WorkflowNode 'Balloon' '读取 Python 输出' 500 20 ([pscustomobject]@{ Title='Python test'; Message='exit={{var.pythonResult.ExitCode}};{{var.pythonResult.StdOut}}' })
        $pythonEnd = New-WorkflowNode 'End' '结束' 760 20
        $pythonWorkflow = [pscustomobject]@{ Id='python-test'; Name='Python node test'; Enabled=$false; Nodes=@($pythonStart,$pythonCall,$pythonOutput,$pythonEnd); Edges=@((New-WorkflowEdge $pythonStart.Id $pythonCall.Id),(New-WorkflowEdge $pythonCall.Id $pythonOutput.Id),(New-WorkflowEdge $pythonOutput.Id $pythonEnd.Id)) }
        $pythonEvents = @(Invoke-SelfTestWorkflow $pythonWorkflow)
        $pythonStarted = @($pythonEvents | Where-Object { $_.Kind -eq 'CommandStarted' -and [string]$_.Data.ProcessKind -eq 'Python' -and [bool]$_.Data.UnlimitedWait } | Select-Object -First 1)
        $pythonBalloon = @($pythonEvents | Where-Object Kind -eq 'Balloon' | Select-Object -First 1)
        if($pythonStarted.Count-ne1-or$pythonBalloon.Count-ne1-or@($pythonEvents|Where-Object{ $_.Kind-eq'CommandOutput'-and[string]$_.Data.ProcessKind-eq'Python' }).Count-lt3){throw 'Python node did not expose its process, real-time output, or output variable.'}
        $pythonText=[string]$pythonBalloon[0].Message
        foreach($expectedText in @('exit=0;','ARGS=3','ARG1=alpha','ARG2=two words',('CWD='+$fakeCodexDirectory))){if($pythonText.IndexOf($expectedText,[StringComparison]::Ordinal)-lt0){throw "Python argument, working directory, or variable flow failed: $expectedText; output=$pythonText"}}
    } finally {
        $script:GlobalSettings.CodexPath = $previousGlobalCodexPath
        [Environment]::SetEnvironmentVariable('POWERUI_CODEX_TEST_EXE', $previousCodexTestExe, 'Process')
        [Environment]::SetEnvironmentVariable('POWERUI_CODEX_TEST_DIR', $previousCodexTestDirectory, 'Process')
    }

    $example = New-CodexClaimWorkflow
    $exampleVariables = @($example.Nodes | Where-Object Type -eq 'EnvWrite' | Select-Object -First 1)
    if (@($example.Nodes).Count -ne 6 -or @($example.Edges).Count -ne 5 -or $exampleVariables.Count -ne 1 -or @($exampleVariables[0].Config.Items).Count -ne 3) { throw 'Codex example graph is invalid.' }
    $dynamicExample = New-DynamicVariableExampleWorkflow
    $dynamicCmd = @($dynamicExample.Nodes | Where-Object Type -eq 'Cmd' | Select-Object -First 1)[0]
    $dynamicBalloon = @($dynamicExample.Nodes | Where-Object Type -eq 'Balloon' | Select-Object -First 1)[0]
    if ($dynamicCmd.Config.OutputVar -ne 'randomResult' -or $dynamicBalloon.Config.Message -ne 'CMD 生成的随机数：{{var.randomResult.StdOut}}') { throw 'Dynamic variable example is invalid.' }
    $dynamicWorker = Start-WorkerProcess $dynamicExample
    $dynamicDeadline = (Get-Date).AddSeconds(30)
    while (-not $dynamicWorker.Process.HasExited -and (Get-Date) -lt $dynamicDeadline) { Start-Sleep -Milliseconds 100 }
    if (-not $dynamicWorker.Process.HasExited) { Stop-Process -Id $dynamicWorker.Process.Id -Force -ErrorAction SilentlyContinue; throw 'Dynamic variable example timed out.' }
    $dynamicLines = @()
    if (Test-Path -LiteralPath $dynamicWorker.OutputPath) { $dynamicLines = @((Read-TextFileWithRetry $dynamicWorker.OutputPath) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    foreach ($path in @($dynamicWorker.InputPath, $dynamicWorker.OutputPath, $dynamicWorker.ErrorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $dynamicEvents = @($dynamicLines | ForEach-Object { [string]$_ | ConvertFrom-Json })
    $dynamicBalloonEvent = @($dynamicEvents | Where-Object Kind -eq 'Balloon' | Select-Object -First 1)
    if ($dynamicBalloonEvent.Count -ne 1 -or [string]$dynamicBalloonEvent[0].Message -notmatch '^CMD 生成的随机数：[0-9]{6}$') { throw 'Dynamic CMD output was not available to the balloon node.' }
    $controlStart = New-WorkflowNode 'Start' '开始' 20 20
    $controlList = New-WorkflowNode 'Variable' '列表变量' 220 20 ([pscustomobject]@{ Name = 'numbers'; ValueType = 'Json'; Value = '[1,2,3]' })
    $controlLoop = New-WorkflowNode 'ForEach' '循环数字' 420 20 ([pscustomobject]@{ Items = '{{var.numbers}}'; ItemVariable = 'number'; IndexVariable = 'itemIndex'; ResultVariable = 'loopResult' })
    $controlDelay = New-WorkflowNode 'Delay' '短延时' 620 20 ([pscustomobject]@{ Seconds = 0.01 })
    $controlCapture = New-WorkflowNode 'Variable' '保存当前值' 820 20 ([pscustomobject]@{ Name = 'last'; ValueType = 'String'; Value = '{{var.number}}' })
    $controlLoopEnd = New-WorkflowNode 'LoopEnd' '循环结束' 1020 20
    $controlIf = New-WorkflowNode 'If' '检查循环次数' 620 160 ([pscustomobject]@{ Left = '{{var.loopResult.Count}}'; Operator = 'Equals'; Right = '3'; OutputVar = 'loopOk' })
    $controlOk = New-WorkflowNode 'Balloon' '成功分支' 840 130 ([pscustomobject]@{ Title = 'Control test'; Message = 'loop={{var.loopResult.Count}},last={{var.last}},index={{var.itemIndex}}' })
    $controlBad = New-WorkflowNode 'Balloon' '失败分支' 840 250 ([pscustomobject]@{ Title = 'Control test'; Message = 'unexpected branch' })
    $controlEnd = New-WorkflowNode 'End' '结束' 1080 160
    $controlWorkflow = [pscustomobject]@{ Id = 'control-test'; Name = 'Control test'; Enabled = $false; IntervalMinutes = 60; NextRunUtc = (Get-Date).ToUniversalTime().ToString('o'); Nodes = @($controlStart,$controlList,$controlLoop,$controlDelay,$controlCapture,$controlLoopEnd,$controlIf,$controlOk,$controlBad,$controlEnd); Edges = @((New-WorkflowEdge $controlStart.Id $controlList.Id),(New-WorkflowEdge $controlList.Id $controlLoop.Id),(New-WorkflowEdge $controlLoop.Id $controlDelay.Id 'Body'),(New-WorkflowEdge $controlLoop.Id $controlIf.Id 'Done'),(New-WorkflowEdge $controlDelay.Id $controlCapture.Id),(New-WorkflowEdge $controlCapture.Id $controlLoopEnd.Id),(New-WorkflowEdge $controlIf.Id $controlOk.Id 'True'),(New-WorkflowEdge $controlIf.Id $controlBad.Id 'False'),(New-WorkflowEdge $controlOk.Id $controlEnd.Id),(New-WorkflowEdge $controlBad.Id $controlEnd.Id)); UpdatedAt = (Get-Date).ToString('o') }
    $controlWorker = Start-WorkerProcess $controlWorkflow
    $controlDeadline = (Get-Date).AddSeconds(30)
    while (-not $controlWorker.Process.HasExited -and (Get-Date) -lt $controlDeadline) { Start-Sleep -Milliseconds 100 }
    if (-not $controlWorker.Process.HasExited) { Stop-Process -Id $controlWorker.Process.Id -Force -ErrorAction SilentlyContinue; throw 'Control-flow example timed out.' }
    $controlLines = @()
    if (Test-Path -LiteralPath $controlWorker.OutputPath) { $controlLines = @((Read-TextFileWithRetry $controlWorker.OutputPath) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    foreach ($path in @($controlWorker.InputPath,$controlWorker.OutputPath,$controlWorker.ErrorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $controlEvents = @($controlLines | ForEach-Object { [string]$_ | ConvertFrom-Json })
    $controlBalloon = @($controlEvents | Where-Object Kind -eq 'Balloon' | Select-Object -First 1)
    if ($controlBalloon.Count -ne 1 -or [string]$controlBalloon[0].Message -ne 'loop=3,last=3,index=3') { throw 'Variable, foreach, delay, or conditional control flow failed.' }
    if (@($controlEvents | Where-Object { $_.Kind -eq 'Log' -and $_.Message -like '*执行第 */3 项*' }).Count -ne 3) { throw 'ForEach node did not execute three iterations.' }
    $exampleSet = @((New-RandomBranchExampleWorkflow),(New-ChecklistLoopExampleWorkflow),(New-SystemSnapshotExampleWorkflow))
    if ($exampleSet.Count -ne 3 -or @($exampleSet | Where-Object Enabled).Count -ne 0) { throw 'Built-in examples are invalid.' }
    $randomEvents = @(Invoke-SelfTestWorkflow $exampleSet[0])
    if (@($randomEvents | Where-Object Kind -eq 'Balloon').Count -ne 1) { throw 'Random branch example did not choose exactly one branch.' }
    $checklistEvents = @(Invoke-SelfTestWorkflow $exampleSet[1])
    if (@($checklistEvents | Where-Object Kind -eq 'Balloon').Count -ne 4) { throw 'Checklist loop example did not emit three items and one summary.' }
    $snapshotEvents = @(Invoke-SelfTestWorkflow $exampleSet[2] 45)
    $snapshotBalloon = @($snapshotEvents | Where-Object Kind -eq 'Balloon' | Select-Object -First 1)
    if ($snapshotBalloon.Count -ne 1 -or [string]$snapshotBalloon[0].Message -notlike '*可用内存约*') { throw 'System snapshot variable flow failed.' }
    $baseUtc = [datetime]::Parse('2026-08-10T00:00:00Z').ToUniversalTime()
    $schedule = [pscustomobject]@{ Id = 'schedule-test'; Enabled = $true; ScheduleMode = 'Loop'; ScheduleKind = 'Interval'; ScheduleTime = '09:30:15'; ScheduleWeekdays = '1,3,5'; ScheduleDayOfMonth = 15; IntervalMinutes = 7; NextRunUtc = '' }
    if (((Get-NextWorkflowRunUtc $schedule $baseUtc) - $baseUtc).TotalMinutes -ne 7) { throw 'Interval schedule calculation failed.' }
    foreach ($kind in @('Daily','Weekly','Monthly','NextTime')) {
        $schedule.ScheduleKind = $kind
        if ((Get-NextWorkflowRunUtc $schedule $baseUtc -Validate) -le $baseUtc) { throw "Schedule calculation failed: $kind" }
    }
    $schedule.ScheduleMode = 'Once'; $schedule.ScheduleKind = 'Interval'; Complete-WorkflowSchedule $schedule
    if ($schedule.Enabled -or -not [string]::IsNullOrWhiteSpace([string]$schedule.NextRunUtc)) { throw 'One-time schedule completion failed.' }
    $script:Workflows = @($workflow, $example, $dynamicExample, $controlWorkflow)
    $project = New-Project 'Self test project' $fakeCodexDirectory 'project-session-id'
    $project.CodexModel = 'gpt-5.4 test'
    $script:Projects = @($project)
    $interactiveCommand = New-CodexInteractiveResumeCommand $fakeCodexPath $fakeCodexDirectory 'project-session-id' ([string]$project.CodexModel)
    foreach ($expectedText in @((ConvertTo-NativeArgument $fakeCodexPath),' --yolo -C ',(ConvertTo-NativeArgument $fakeCodexDirectory),' --model "gpt-5.4 test" resume project-session-id')) {
        if ($interactiveCommand.IndexOf($expectedText, [StringComparison]::Ordinal) -lt 0) { throw "Interactive Codex resume command is invalid: $interactiveCommand" }
    }
    $conversationArguments = New-CodexExecResumeArguments 'project-session-id' 'message with spaces' 'gpt-5.4 test'
    if ($conversationArguments -ne 'exec --yolo --skip-git-repo-check --model "gpt-5.4 test" resume project-session-id "message with spaces"') { throw "Embedded Codex resume arguments are invalid: $conversationArguments" }
    $projectConversationOutput=Join-Path $testDirectory 'project-response.txt'
    $newProjectArguments=New-ProjectCodexArguments '' 'first project message' $fakeCodexDirectory $projectConversationOutput 'gpt-5.4 test'
    if($newProjectArguments-notlike 'exec --yolo --skip-git-repo-check --json -o * --model "gpt-5.4 test" -C * "first project message"'-or$newProjectArguments-like'* resume *'){throw "Project new-session arguments are invalid: $newProjectArguments"}
    $resumeProjectArguments=New-ProjectCodexArguments 'project-session-id' 'continue project' $fakeCodexDirectory $projectConversationOutput ''
    if($resumeProjectArguments-notlike 'exec --yolo --skip-git-repo-check --json -o * resume project-session-id "continue project"'-or$resumeProjectArguments-like'* --model *'){throw "Project resume arguments are invalid: $resumeProjectArguments"}
    $imageFixturePath=Join-Path $testDirectory 'image-fixture.png';$imageFixture=New-Object Drawing.Bitmap -ArgumentList 8,8;try{$imageFixture.Save($imageFixturePath,[Drawing.Imaging.ImageFormat]::Png)}finally{$imageFixture.Dispose()}
    $imageProjectArguments=New-ProjectCodexArguments -SessionId 'project-session-id' -Prompt 'image prompt' -WorkingDirectory $fakeCodexDirectory -OutputPath $projectConversationOutput -ImagePaths @($imageFixturePath)
    $imageArgumentToken=ConvertTo-NativeArgument $imageFixturePath
    if($imageProjectArguments-notlike ('* resume -i '+$imageArgumentToken+' project-session-id "image prompt"')){throw "Project image arguments are invalid: $imageProjectArguments"}
    $imagePrompt=Get-CodexConversationPromptWithImages 'check this' @([pscustomobject]@{Path=$imageFixturePath})
    if($imagePrompt-notlike '*附带图片*'-or$imagePrompt-notlike ('*'+$imageFixturePath+'*')){throw 'Image attachment prompt did not preserve the local path.'}
    $legacyProject=Normalize-Project ([pscustomobject]@{Id='legacy-project';Name='Legacy';DefaultWorkingDirectory=$fakeCodexDirectory;CodexSessionId='';UpdatedAt=''})
    if($null-eq$legacyProject.PSObject.Properties['CodexModel']-or[string]$legacyProject.CodexModel-ne''){throw 'Legacy project model normalization failed.'}
    $pendingSessionProject=New-Project 'Pending session project' $fakeCodexDirectory '' 'gpt-pending'
    $pendingSessions=@(Get-ProjectCodexSessions $pendingSessionProject)
    if($pendingSessions.Count-ne1-or-not[string]::IsNullOrWhiteSpace([string]$pendingSessions[0].SessionId)-or[string]$pendingSessions[0].CodexModel-ne'gpt-pending'){throw 'Empty Codex session configuration was not preserved.'}
    $pendingDescriptionProject=New-Project 'Pending description project' $fakeCodexDirectory '' '' @([pscustomobject]@{SessionId='';CodexModel='';Description='临时提问'})
    $pendingDescriptionSessions=@(Get-ProjectCodexSessions $pendingDescriptionProject)
    if($pendingDescriptionSessions.Count-ne1-or-not[string]::IsNullOrWhiteSpace([string]$pendingDescriptionSessions[0].SessionId)-or[string]$pendingDescriptionSessions[0].Description-ne'临时提问'){throw 'Empty Codex session description configuration was not preserved.'}
    $firstProject=New-Project 'First message project' $fakeCodexDirectory '' 'gpt-5.4 test'
    $script:Projects=@($firstProject)
    $firstOutput=Join-Path $testDirectory 'first-project-response.txt'
    $firstInfo=New-Object Diagnostics.ProcessStartInfo;$firstInfo.FileName=$fakeCodexPath;$firstInfo.Arguments=New-ProjectCodexArguments '' 'create the project session' $fakeCodexDirectory $firstOutput ([string]$firstProject.CodexModel);$firstInfo.WorkingDirectory=$fakeCodexDirectory;$firstInfo.UseShellExecute=$false;$firstInfo.CreateNoWindow=$true;$firstInfo.RedirectStandardOutput=$true;$firstInfo.RedirectStandardError=$true
    $firstProcess=New-Object Diagnostics.Process;$firstProcess.StartInfo=$firstInfo
    if(-not$firstProcess.Start()){throw 'Fake project Codex process did not start.'}
    $firstRecord=[pscustomobject]@{Key='Project:'+([string]$firstProject.Id);Process=$firstProcess;Mode='Project';ProjectId=[string]$firstProject.Id;SessionId='';InitialSessionId='';Model=[string]$firstProject.CodexModel;OutputPath=$firstOutput;StdOut=$firstProcess.StandardOutput.ReadToEndAsync();StdErr=$firstProcess.StandardError.ReadToEndAsync();StartedAt=Get-Date}
    $script:CodexConversationProcesses[$firstRecord.Key]=$firstRecord
    $firstProcess.WaitForExit();Complete-ProjectCodexMessage
    $firstProjectSessions=@(Get-ProjectCodexSessions $firstProject)
    if([string]$firstProject.CodexSessionId-ne'019fffff-project-created-session'-or$firstProjectSessions.Count-ne1-or[string]$firstProjectSessions[0].SessionId-ne'019fffff-project-created-session'-or$script:CodexConversationProcesses.ContainsKey($firstRecord.Key)){throw 'First project message did not bind and complete the newly created Codex session.'}
    if(-not(Test-Path -LiteralPath $firstOutput)-or[IO.File]::ReadAllText($firstOutput,[Text.Encoding]::UTF8)-ne'Fake Codex final response'){throw 'First project message did not capture the final Codex response.'}
    $webConversationProject=New-Project 'Web conversation project' $fakeCodexDirectory '' '' @([pscustomobject]@{SessionId='';CodexModel='';Description='First pending'},[pscustomobject]@{SessionId='';CodexModel='gpt-web';Description='Second pending'})
    $script:Projects=@($webConversationProject)
    $webPendingSessions=@(Get-ProjectCodexSessions $webConversationProject)
    $webPreviousCodexPath=[string]$script:GlobalSettings.CodexPath;$script:GlobalSettings.CodexPath=$fakeCodexPath
    $webStarted=Start-ProjectCodexConversationRequest $webConversationProject $webPendingSessions[1] 1 'web message' 'Web' @()
    if(-not$webStarted.Started-or[string]$webStarted.SessionKey-ne'_new-1'-or-not$script:CodexConversationProcesses.ContainsKey([string]$webStarted.ProcessKey)){throw 'Web Codex request did not use the indexed pending-session route.'}
    $webConversationDeadline=(Get-Date).AddSeconds(10)
    while($script:CodexConversationProcesses.ContainsKey([string]$webStarted.ProcessKey)-and(Get-Date)-lt$webConversationDeadline){Complete-ProjectCodexMessage;Start-Sleep -Milliseconds 25}
    $script:GlobalSettings.CodexPath=$webPreviousCodexPath
    $webBoundSessions=@(Get-ProjectCodexSessions $webConversationProject)
    if($webBoundSessions.Count-ne2-or-not[string]::IsNullOrWhiteSpace([string]$webBoundSessions[0].SessionId)-or[string]$webBoundSessions[1].SessionId-ne'019fffff-project-created-session'){throw 'Web Codex request did not bind the created session to the selected pending row.'}
    $script:Projects=@($project)
    $script:WorkflowAiDirectory = Join-Path $testDirectory 'workflow-ai'
    $resolvedWorkflowAiSkillPath = Get-WorkflowAiSkillPath
    $workflowAiPrompt = Get-WorkflowAiPrompt '整理最近 10 个会话为项目'
    foreach($requiredText in @((Join-Path $resolvedWorkflowAiSkillPath 'SKILL.md'),'http://127.0.0.1:5169','isolated persistent session','整理最近 10 个会话为项目')){if($workflowAiPrompt.IndexOf($requiredText,[StringComparison]::OrdinalIgnoreCase)-lt0){throw '使驾 AI prompt is missing its skill, API, isolation, or user request context.'}}
    $workflowAiOutput = Join-Path $script:WorkflowAiDirectory 'last-response.txt'
    $newAiArguments = New-WorkflowAiCodexArguments '' 'message with spaces' $workflowAiOutput
    if($newAiArguments -notlike 'exec --yolo --skip-git-repo-check --json -o * -C * "message with spaces"' -or $newAiArguments -like '* resume *'){throw "Workflow AI new-session arguments are invalid: $newAiArguments"}
    $resumeAiArguments = New-WorkflowAiCodexArguments '019fffff-aaaa-bbbb-cccc-111111111111' 'continue work' $workflowAiOutput
    if($resumeAiArguments -notlike 'exec --yolo --skip-git-repo-check --json -o * resume 019fffff-aaaa-bbbb-cccc-111111111111 "continue work"'){throw "Workflow AI resume arguments are invalid: $resumeAiArguments"}
    $imageAiArguments=New-WorkflowAiCodexArguments -SessionId '019fffff-aaaa-bbbb-cccc-111111111111' -Prompt 'image work' -OutputPath $workflowAiOutput -ImagePaths @($imageFixturePath)
    if($imageAiArguments-notlike ('* resume -i '+$imageArgumentToken+' 019fffff-aaaa-bbbb-cccc-111111111111 "image work"')){throw "Workflow AI image arguments are invalid: $imageAiArguments"}
    $eventLines = '{"type":"thread.started","thread_id":"019fffff-aaaa-bbbb-cccc-111111111111"}' + "`n" + '{"type":"turn.completed"}'
    if((Get-CodexJsonSessionId $eventLines)-ne'019fffff-aaaa-bbbb-cccc-111111111111'){throw 'Workflow AI JSON session ID parsing failed.'}
    $projectNameBox=New-Object Windows.Forms.TextBox;$projectDirectoryBox=New-Object Windows.Forms.TextBox;$projectSessionBox=New-Object Windows.Forms.TextBox
    Set-ProjectEditorFromCodexSession ([pscustomobject]@{working_directory=$fakeCodexDirectory;session_id='picked-session';title='Picked session'}) $projectNameBox $projectDirectoryBox $projectSessionBox
    if($projectDirectoryBox.Text-ne$fakeCodexDirectory-or$projectSessionBox.Text-ne'picked-session'-or[string]::IsNullOrWhiteSpace($projectNameBox.Text)){throw 'Project session picker mapping failed.'}
    $projectNameBox.Clear();$projectDirectoryBox.Text='existing-directory';$projectSessionBox.Clear()
    Set-ProjectEditorFromCodexSession ([pscustomobject]@{working_directory='';session_id='empty-directory-session';title='Empty directory session'}) $projectNameBox $projectDirectoryBox $projectSessionBox
    if($projectDirectoryBox.Text-ne'existing-directory'-or$projectSessionBox.Text-ne'empty-directory-session'-or$projectNameBox.Text-ne'Empty directory session'){throw 'Project session picker empty-directory fallback failed.'}
    $projectNameBox.Dispose();$projectDirectoryBox.Dispose();$projectSessionBox.Dispose()
    $projectWorkflow = New-DefaultWorkflow 'Project workflow' ([string]$project.Id)
    $projectCmd = New-WorkflowNode 'Cmd' 'Project CMD' 220 20 ([pscustomobject]@{ Command='echo ok'; WorkingDirectory=''; TimeoutSeconds=10; OutputVar='cmd'; FailOnError=$true })
    $projectPython = New-WorkflowNode 'Python' 'Project Python' 440 20 ([pscustomobject]@{ Mode='Inline'; Script='print("ok")'; WorkingDirectory=''; TimeoutSeconds=''; OutputVar='python'; FailOnError=$true })
    $projectCodex = New-WorkflowNode 'Codex' 'Project Codex' 440 20 ([pscustomobject]@{ WorkingDirectory=''; SessionId=''; Request='ok'; LiveData=''; TimeoutSeconds=10; OutputVar='codex'; FailOnError=$true })
    $projectWorkflow.Nodes = @($projectWorkflow.Nodes[0],$projectCmd,$projectPython,$projectCodex,$projectWorkflow.Nodes[1])
    $projectWorkflow.Edges = @((New-WorkflowEdge $projectWorkflow.Nodes[0].Id $projectCmd.Id),(New-WorkflowEdge $projectCmd.Id $projectPython.Id),(New-WorkflowEdge $projectPython.Id $projectCodex.Id),(New-WorkflowEdge $projectCodex.Id $projectWorkflow.Nodes[4].Id))
    $previousGlobalPythonPath=[string]$script:GlobalSettings.PythonInterpreterPath
    try{$script:GlobalSettings.PythonInterpreterPath=$fakeCodexPath;$effectiveProjectWorkflow = Get-EffectiveWorkflowForRun $projectWorkflow}finally{$script:GlobalSettings.PythonInterpreterPath=$previousGlobalPythonPath}
    $effectiveCmd = @($effectiveProjectWorkflow.Nodes | Where-Object Type -eq 'Cmd')[0]
    $effectivePython = @($effectiveProjectWorkflow.Nodes | Where-Object Type -eq 'Python')[0]
    $effectiveCodex = @($effectiveProjectWorkflow.Nodes | Where-Object Type -eq 'Codex')[0]
    if ($effectiveCmd.Config.WorkingDirectory -ne $fakeCodexDirectory -or $effectivePython.Config.WorkingDirectory-ne$fakeCodexDirectory-or$effectivePython.Config.InterpreterPath-ne$fakeCodexPath-or$effectiveCodex.Config.WorkingDirectory -ne $fakeCodexDirectory -or $effectiveCodex.Config.SessionId -ne 'project-session-id' -or $effectiveCodex.Config.Model -ne 'gpt-5.4 test') { throw 'Project or global defaults were not injected into workflow execution.' }
    $workflowsBeforeOrder=@($script:Workflows)
    $otherProject=New-Project 'Other project' $fakeCodexDirectory 'other-session'
    $orderA=New-DefaultWorkflow 'Order A' ([string]$project.Id);$orderB=New-DefaultWorkflow 'Order B' ([string]$project.Id);$orderOther=New-DefaultWorkflow 'Order Other' ([string]$otherProject.Id)
    $script:Workflows=@($orderA,$orderOther,$orderB)
    if(-not(Move-SelectedWorkflow -Direction -1 -Workflow $orderB -NoRefresh)){throw 'Workflow move-up operation failed.'}
    if([string]$script:Workflows[0].Id-ne[string]$orderB.Id-or[string]$script:Workflows[1].Id-ne[string]$orderOther.Id-or[string]$script:Workflows[2].Id-ne[string]$orderA.Id){throw 'Workflow move changed another project position or failed to swap same-project neighbors.'}
    if((Get-WorkflowMoveState $orderB).CanMoveUp-or-not(Get-WorkflowMoveState $orderB).CanMoveDown){throw 'Workflow move boundary state is invalid.'}
    if(Move-SelectedWorkflow -Direction -1 -Workflow $orderB -NoRefresh){throw 'Workflow moved beyond the top boundary.'}
    if(-not(Move-SelectedWorkflow -Direction 1 -Workflow $orderB -NoRefresh)){throw 'Workflow move-down operation failed.'}
    $script:Workflows=$workflowsBeforeOrder;$script:CurrentWorkflow=$null
    $script:Workflows += $projectWorkflow
    $exportPath = Join-Path $testDirectory 'export.json'
    Export-WorkflowConfigurationToPath $exportPath
    $roundTrip = @(Import-WorkflowConfigurationFromPath $exportPath)
    $applicationRoundTrip = Import-ApplicationConfigurationFromPath $exportPath
    if ($roundTrip.Count -ne 5 -or @($roundTrip | Where-Object Name -eq $dynamicExample.Name).Count -ne 1 -or @($applicationRoundTrip.Projects).Count -ne 1 -or [string]$applicationRoundTrip.Projects[0].Name -ne 'Self test project') { throw 'Configuration export/import round trip failed.' }

    $apiProjectDirectory = Join-Path $testDirectory 'API project'
    $sessionDirectory = Join-Path $script:CodexSessionsDirectory '2026\08\12'
    [IO.Directory]::CreateDirectory($apiProjectDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
    $apiSessionId = '019fffff-1111-7222-8333-444444444444'
    $sessionMeta = [pscustomobject]@{ timestamp='2026-08-12T03:00:00.000Z'; type='session_meta'; payload=[pscustomobject]@{ session_id=$apiSessionId; id=$apiSessionId; timestamp='2026-08-12T03:00:00.000Z'; cwd=$apiProjectDirectory; source='cli' } }
    $sessionTitle = [pscustomobject]@{ timestamp='2026-08-12T03:00:01.000Z'; type='response_item'; payload=[pscustomobject]@{ type='message'; role='user'; content=@([pscustomobject]@{ type='input_text'; text='开发 WorkflowManager HTTP 接口' }) } }
    $sessionPath = Join-Path $sessionDirectory ('rollout-' + $apiSessionId + '.jsonl')
    [IO.File]::WriteAllText($sessionPath, (($sessionMeta | ConvertTo-Json -Depth 8 -Compress) + "`n" + ($sessionTitle | ConvertTo-Json -Depth 8 -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::SetLastWriteTimeUtc($sessionPath, [datetime]'2026-08-12T03:01:00.000Z')
    $duplicateSessionMeta = [pscustomobject]@{ timestamp='2026-08-12T03:05:00.000Z'; type='session_meta'; payload=[pscustomobject]@{ session_id=$apiSessionId; id=$apiSessionId; timestamp='2026-08-12T03:05:00.000Z'; cwd=$apiProjectDirectory; source='cli' } }
    $duplicateSessionPath = Join-Path $sessionDirectory ('rollout-copy-' + $apiSessionId + '.jsonl')
    [IO.File]::WriteAllText($duplicateSessionPath, (($duplicateSessionMeta | ConvertTo-Json -Depth 8 -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::SetLastWriteTimeUtc($duplicateSessionPath, [datetime]'2026-08-12T03:06:00.000Z')

    $conversationUser = [pscustomobject]@{ timestamp='2026-08-12T03:00:02.000Z'; type='event_msg'; payload=[pscustomobject]@{ type='user_message'; message='测试恢复历史' } }
    $conversationAssistant = [pscustomobject]@{ timestamp='2026-08-12T03:00:03.000Z'; type='event_msg'; payload=[pscustomobject]@{ type='agent_message'; message='历史已恢复'; phase='final' } }
    [IO.File]::AppendAllText($duplicateSessionPath, (($conversationUser | ConvertTo-Json -Depth 8 -Compress) + "`n" + ($conversationAssistant | ConvertTo-Json -Depth 8 -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
    $script:CodexSessionCacheAt=[datetime]::MinValue
    $conversationResult=Get-CodexSessionConversation $apiSessionId 20 -Refresh
    if(-not$conversationResult.Found-or@($conversationResult.Messages).Count-ne2-or$conversationResult.Messages[0].Text-ne'测试恢复历史'-or$conversationResult.Messages[1].Text-ne'历史已恢复'){throw ('Codex session conversation loading failed: '+($conversationResult|ConvertTo-Json -Depth 8 -Compress))}
    $syntheticWarning=[pscustomobject]@{timestamp='2026-08-12T03:00:02.100Z';type='response_item';payload=[pscustomobject]@{type='message';role='user';content=@([pscustomobject]@{type='input_text';text='Warning: apply_patch was requested via shell. Use the apply_patch tool instead of exec_command.'})}}
    $canonicalImageUser=[pscustomobject]@{timestamp='2026-08-12T03:00:02.200Z';type='event_msg';payload=[pscustomobject]@{type='user_message';message='带图真实用户消息';local_images=@('C:\temp\fixture.png')}}
    $filteredMessages=@(ConvertFrom-CodexConversationLines @(($syntheticWarning|ConvertTo-Json -Depth 8 -Compress),($canonicalImageUser|ConvertTo-Json -Depth 8 -Compress)))
    if($filteredMessages.Count-ne1-or$filteredMessages[0].Role-ne'user'-or$filteredMessages[0].Text-ne'带图真实用户消息'-or(Test-CodexConversationDisplayMessage 'user' 'Warning: apply_patch was requested via shell. Use the apply_patch tool instead of exec_command.')-or(Test-CodexConversationDisplayMessage 'assistant' '诊断信息：测试 stderr')){throw 'Synthetic Codex user/diagnostic message filtering failed.'}
    $taskCompleteMessage=[pscustomobject]@{timestamp='2026-08-12T03:00:02.300Z';type='event_msg';payload=[pscustomobject]@{type='task_complete';last_agent_message='任务完成后的最终 Markdown 回复'}}
    $taskCompleteMessages=@(ConvertFrom-CodexConversationLines @(($taskCompleteMessage|ConvertTo-Json -Depth 8 -Compress)))
    if($taskCompleteMessages.Count-ne1-or$taskCompleteMessages[0].Role-ne'assistant'-or$taskCompleteMessages[0].Text-ne'任务完成后的最终 Markdown 回复'){throw 'Codex task_complete final message parsing failed.'}
    $initialConversationOffset=[long]$script:CodexConversationSnapshots[$apiSessionId].Offset
    $conversationDelta=[pscustomobject]@{timestamp='2026-08-12T03:00:04.000Z';type='event_msg';payload=[pscustomobject]@{type='agent_message';message='增量追加成功';phase='final'}}
    [IO.File]::AppendAllText($duplicateSessionPath,(($conversationDelta|ConvertTo-Json -Depth 8 -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
    $incrementalConversation=Get-CodexSessionConversation $apiSessionId 20
    if(@($incrementalConversation.AddedMessages).Count-ne1-or$incrementalConversation.AddedMessages[0].Text-ne'增量追加成功'-or@($incrementalConversation.Messages).Count-ne3-or[long]$script:CodexConversationSnapshots[$apiSessionId].Offset-le$initialConversationOffset){throw 'Codex conversation incremental append failed.'}
    $completedOffset=[long]$script:CodexConversationSnapshots[$apiSessionId].Offset
    $partialConversation=[pscustomobject]@{timestamp='2026-08-12T03:00:05.000Z';type='event_msg';payload=[pscustomobject]@{type='agent_message';message='半行补齐成功';phase='final'}}|ConvertTo-Json -Depth 8 -Compress
    $partialSplit=[Math]::Floor($partialConversation.Length/2)
    [IO.File]::AppendAllText($duplicateSessionPath,$partialConversation.Substring(0,$partialSplit),(New-Object Text.UTF8Encoding($false)))
    $partialResult=Get-CodexSessionConversation $apiSessionId 20
    if(@($partialResult.AddedMessages).Count-ne0-or[long]$script:CodexConversationSnapshots[$apiSessionId].Offset-ne$completedOffset){throw 'Codex conversation exposed an incomplete JSONL line.'}
    [IO.File]::AppendAllText($duplicateSessionPath,($partialConversation.Substring($partialSplit)+"`n"),(New-Object Text.UTF8Encoding($false)))
    $completedPartialResult=Get-CodexSessionConversation $apiSessionId 20
    if(@($completedPartialResult.AddedMessages).Count-ne1-or$completedPartialResult.AddedMessages[0].Text-ne'半行补齐成功'-or[long]$script:CodexConversationSnapshots[$apiSessionId].Offset-le$completedOffset){throw 'Codex conversation did not resume from the previous complete-line offset.'}
    Add-CodexMessageToSnapshot $apiSessionId 'user' '即时用户消息'
    Add-CodexMessageToSnapshot $apiSessionId 'assistant' '即时回复消息'
    $instantUserResponse=[pscustomobject]@{timestamp='2026-08-12T03:00:05.900Z';type='response_item';payload=[pscustomobject]@{type='message';role='user';content=@([pscustomobject]@{type='input_text';text='即时用户消息'},[pscustomobject]@{type='input_image';image_url='C:\temp\fixture.png'})}}
    $instantUser=[pscustomobject]@{timestamp='2026-08-12T03:00:06.000Z';type='event_msg';payload=[pscustomobject]@{type='user_message';message='即时用户消息'}}
    $instantAssistant=[pscustomobject]@{timestamp='2026-08-12T03:00:07.000Z';type='event_msg';payload=[pscustomobject]@{type='agent_message';message='即时回复消息';phase='final'}}
    [IO.File]::AppendAllText($duplicateSessionPath,(($instantUserResponse|ConvertTo-Json -Depth 8 -Compress)+"`n"+($instantUser|ConvertTo-Json -Depth 8 -Compress)+"`n"+($instantAssistant|ConvertTo-Json -Depth 8 -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
    $deduplicatedConversation=Get-CodexSessionConversation $apiSessionId 20
    if(@($deduplicatedConversation.AddedMessages).Count-ne0-or@($deduplicatedConversation.Messages|Where-Object{$_.Text-eq'即时用户消息'}).Count-ne1-or@($deduplicatedConversation.Messages|Where-Object{$_.Text-eq'即时回复消息'}).Count-ne1-or@($script:CodexConversationSnapshots[$apiSessionId].PendingMessages).Count-ne0){throw 'Codex conversation snapshot did not deduplicate locally displayed messages.'}

    $health = Invoke-WorkflowApiOperation 'GET' '/api/health'
    if ($health.StatusCode -ne 200 -or ($health.Body | ConvertFrom-Json).data.authentication -ne 'none') { throw 'API health response is invalid.' }
    $sessionResponse = Invoke-WorkflowApiOperation 'GET' ('/api/codex/sessions?workingDirectory=' + [Uri]::EscapeDataString($apiProjectDirectory) + '&limit=5')
    $sessionData = ($sessionResponse.Body | ConvertFrom-Json).data
    if ($sessionResponse.StatusCode -ne 200 -or $sessionData.count -ne 1 -or $sessionData.sessions[0].session_id -ne $apiSessionId -or $sessionData.sessions[0].title -ne '开发 WorkflowManager HTTP 接口' -or $sessionData.sessions[0].file -ne $duplicateSessionPath) { throw 'Codex session summary API deduplication is invalid.' }
    $replacementSessionPath=Join-Path $sessionDirectory ('rollout-latest-'+$apiSessionId+'.jsonl')
    $replacementMessage=[pscustomobject]@{timestamp='2026-08-12T03:10:01.000Z';type='event_msg';payload=[pscustomobject]@{type='agent_message';message='新会话文件已切换';phase='final'}}
    [IO.File]::WriteAllText($replacementSessionPath,(($duplicateSessionMeta|ConvertTo-Json -Depth 8 -Compress)+"`n"+($replacementMessage|ConvertTo-Json -Depth 8 -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::SetLastWriteTimeUtc($replacementSessionPath,(Get-Date).ToUniversalTime().AddMinutes(5))
    $replacementConversation=Get-CodexSessionConversation $apiSessionId 20 -Refresh
    if(-not$replacementConversation.Reset-or[string]$replacementConversation.Snapshot.Path-ne$replacementSessionPath-or@($replacementConversation.Messages).Count-ne1-or$replacementConversation.Messages[0].Text-ne'新会话文件已切换'){throw 'Manual conversation refresh did not switch to the latest session file snapshot.'}

    $projectsBefore = (Invoke-WorkflowApiOperation 'GET' '/api/projects').Body | ConvertFrom-Json
    if ($null -eq $projectsBefore.PSObject.Properties['data']) { throw ('API project list failed: ' + ($projectsBefore | ConvertTo-Json -Depth 8 -Compress)) }
    if (@($projectsBefore.data.projects | Where-Object name -eq '无项目').Count -ne 1) { throw 'API project list is missing the ungrouped project.' }
    $createProjectBody = [pscustomobject]@{ name='API project'; defaultWorkingDirectory=$apiProjectDirectory; codexSessionId=$apiSessionId; codexModel='gpt-5.4' } | ConvertTo-Json -Compress
    $createProjectResponse = Invoke-WorkflowApiOperation 'POST' '/api/projects' $createProjectBody
    $createdProject = ($createProjectResponse.Body | ConvertFrom-Json).data
    if ($createProjectResponse.StatusCode -ne 201 -or [string]::IsNullOrWhiteSpace([string]$createdProject.Id) -or [string]$createdProject.CodexModel -ne 'gpt-5.4') { throw 'API project creation failed.' }
    $duplicateProjectResponse = Invoke-WorkflowApiOperation 'POST' '/api/projects' $createProjectBody
    if ($duplicateProjectResponse.StatusCode -ne 409) { throw 'API duplicate project protection failed.' }
    $editProjectBody = [pscustomobject]@{ name='API project edited'; codexSessionId='edited-session'; codexModel='gpt-5.4-mini' } | ConvertTo-Json -Compress
    $editProjectResponse = Invoke-WorkflowApiOperation 'PATCH' ('/api/projects/' + $createdProject.Id) $editProjectBody
    $editedProject=($editProjectResponse.Body | ConvertFrom-Json).data
    if ($editProjectResponse.StatusCode -ne 200 -or $editedProject.name -ne 'API project edited' -or $editedProject.CodexModel -ne 'gpt-5.4-mini') { throw 'API project update failed.' }
    $projectsAfterEdit=(Invoke-WorkflowApiOperation 'GET' '/api/projects').Body|ConvertFrom-Json
    if(@($projectsAfterEdit.data.projects|Where-Object{[string]$_.id-eq[string]$createdProject.Id-and[string]$_.codexModel-eq'gpt-5.4-mini'}).Count-ne1){throw 'API project list omitted the Codex model.'}
    $multiSessionPatch=[pscustomobject]@{codexSessions=@([pscustomobject]@{sessionId='api-main-session';codexModel='gpt-main';description='主会话'},[pscustomobject]@{sessionId='api-question-session';codexModel='gpt-question';description='临时提问'})}|ConvertTo-Json -Depth 8 -Compress
    $multiSessionResponse=Invoke-WorkflowApiOperation 'PATCH' ('/api/projects/'+$createdProject.Id) $multiSessionPatch
    $multiSessionProjectData=($multiSessionResponse.Body|ConvertFrom-Json).data
    if($multiSessionResponse.StatusCode-ne200-or[string]$multiSessionProjectData.CodexSessionId-ne'api-main-session'-or@($multiSessionProjectData.CodexSessions).Count-ne2){throw 'API multi-session project update failed.'}
    $projectsAfterMultiSession=(Invoke-WorkflowApiOperation 'GET' '/api/projects').Body|ConvertFrom-Json
    $listedMultiProject=@($projectsAfterMultiSession.data.projects|Where-Object{[string]$_.id-eq[string]$createdProject.Id}|Select-Object -First 1)
    if($listedMultiProject.Count-ne1-or@($listedMultiProject[0].codexSessions).Count-ne2-or[string]$listedMultiProject[0].codexSessions[1].description-ne'临时提问'){throw 'API project list omitted multi-session descriptions.'}

    $createWorkflowResponse = Invoke-WorkflowApiOperation 'POST' ('/api/projects/' + $createdProject.Id + '/workflows') ([pscustomobject]@{ name='API workflow' } | ConvertTo-Json -Compress)
    $createdWorkflow = ($createWorkflowResponse.Body | ConvertFrom-Json).data
    if ($createWorkflowResponse.StatusCode -ne 201 -or $createdWorkflow.ProjectId -ne $createdProject.Id -or @($createdWorkflow.Nodes).Count -ne 2) { throw 'API workflow creation failed.' }
    $workflowPath = '/api/projects/' + $createdProject.Id + '/workflows/' + $createdWorkflow.Id
    $readWorkflowResponse = Invoke-WorkflowApiOperation 'GET' $workflowPath
    if ($readWorkflowResponse.StatusCode -ne 200 -or (($readWorkflowResponse.Body | ConvertFrom-Json).data.Name) -ne 'API workflow') { throw 'API workflow read failed.' }
    $replacementWorkflow = New-DefaultWorkflow 'API workflow edited' 'wrong-project'
    $replaceWorkflowResponse = Invoke-WorkflowApiOperation 'PUT' $workflowPath ([pscustomobject]@{ workflow=$replacementWorkflow } | ConvertTo-Json -Depth 30 -Compress)
    $replacedWorkflow = ($replaceWorkflowResponse.Body | ConvertFrom-Json).data
    if ($replaceWorkflowResponse.StatusCode -ne 200 -or $replacedWorkflow.Id -ne $createdWorkflow.Id -or $replacedWorkflow.ProjectId -ne $createdProject.Id -or $replacedWorkflow.Name -ne 'API workflow edited') { throw 'API workflow update or project ownership protection failed.' }
    $originResponse = Invoke-WorkflowApiOperation 'GET' '/api/health' '' @{ Origin='https://example.com' }
    if ($originResponse.StatusCode -ne 403) { throw 'API cross-origin protection failed.' }
    $deleteWorkflowResponse = Invoke-WorkflowApiOperation 'DELETE' $workflowPath
    if ($deleteWorkflowResponse.StatusCode -ne 200 -or @($script:Workflows | Where-Object { [string]$_.Id -eq [string]$createdWorkflow.Id }).Count -ne 0) { throw 'API workflow deletion failed.' }
    $transportServer = New-Object WorkflowApiServer
    try {
        $transportServer.Start(0); $script:ApiServer=$transportServer
        $transportClient = New-Object Net.Sockets.TcpClient
        $transportReader = $null
        try {
            $transportClient.Connect('127.0.0.1',$transportServer.Port)
            $transportStream=$transportClient.GetStream()
            $transportRequest="GET /api/health HTTP/1.1`r`nHost: 127.0.0.1:$($transportServer.Port)`r`nConnection: close`r`n`r`n"
            $transportBytes=[Text.Encoding]::ASCII.GetBytes($transportRequest)
            $transportStream.Write($transportBytes,0,$transportBytes.Length)
            $transportReader=New-Object IO.StreamReader($transportStream,[Text.Encoding]::UTF8)
            $transportTask=$transportReader.ReadToEndAsync()
            $transportDeadline=(Get-Date).AddSeconds(20)
            while(-not$transportTask.IsCompleted-and(Get-Date)-lt$transportDeadline){Invoke-PendingWorkflowApiRequests;Start-Sleep -Milliseconds 20}
            if(-not$transportTask.IsCompleted){throw 'HTTP transport self-test timed out.'}
            $transportResponse=[string]$transportTask.Result
            $transportResult=($transportResponse -split "`r`n`r`n",2)[1]
            if(($transportResult|ConvertFrom-Json).data.service-ne'使驾 API'){throw 'HTTP transport returned an invalid response.'}
        } finally { if($null-ne$transportReader){$transportReader.Dispose()};$transportClient.Dispose() }
    } finally { $transportServer.Dispose();$script:ApiServer=$null }
    if (Test-Path -LiteralPath $testDirectory) { [IO.Directory]::Delete($testDirectory, $true) }
    Write-Output 'Self-test passed: worker execution, dynamic variables, schedules, API CRUD, Codex sessions, Workflow AI, file tree, configuration round trip, graph model, and events.'
}

function Invoke-NodeEditorSmokeTest {
    param($Node, [switch]$Save)
    $script:EditorSmokeSave = [bool]$Save
    $script:EditorSmokeTimer = New-Object System.Windows.Forms.Timer
    $script:EditorSmokeTimer.Interval = 100
    $script:EditorSmokeTimer.Add_Tick({
        $editor = @([Windows.Forms.Application]::OpenForms | Where-Object { $_ -ne $script:MainForm -and $_.Text -like '节点配置*' } | Select-Object -Last 1)
        if ($editor.Count -eq 0) { return }
        if ($script:EditorSmokeSave) {
            $saveButton = @($editor[0].Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq '保存节点' } | Select-Object -First 1)
            if ($saveButton.Count -eq 0) { return }
            $saveButton[0].PerformClick()
            if ($editor[0].Visible) { return }
            $script:EditorSmokeTimer.Stop()
            return
        }
        $script:EditorSmokeTimer.Stop()
        $editor[0].DialogResult = [Windows.Forms.DialogResult]::Cancel
        $editor[0].Close()
    })
    try {
        $script:EditorSmokeTimer.Start()
        $result = Show-NodeEditor $Node
        $expectedResult = if ($Save) { [Windows.Forms.DialogResult]::OK } else { [Windows.Forms.DialogResult]::Cancel }
        if ($result -ne $expectedResult) { throw "Node editor did not close cleanly: $($Node.Type)" }
    } finally {
        if ($null -ne $script:EditorSmokeTimer) {
            $script:EditorSmokeTimer.Stop()
            $script:EditorSmokeTimer.Dispose()
        }
        $script:EditorSmokeTimer = $null
        $script:EditorSmokeSave = $false
    }
}

function Invoke-ProjectEditorSmokeTest {
    param($Session)
    $script:ProjectEditorSmokeSession=$Session
    $script:ProjectEditorSmokeError=$null
    $script:ProjectEditorSmokeDeadline=(Get-Date).AddSeconds(12)
    $script:ProjectEditorSmokeTimer=New-Object Windows.Forms.Timer
    $script:ProjectEditorSmokeTimer.Interval=150
    $script:ProjectEditorSmokeTimer.Add_Tick({
        $editor=@([Windows.Forms.Application]::OpenForms|Where-Object{$_.Text-eq'新建项目'}|Select-Object -Last 1)
        if($editor.Count-eq0){if((Get-Date)-gt$script:ProjectEditorSmokeDeadline){$script:ProjectEditorSmokeError='新建项目窗口未能在自动化测试期限内打开。';$script:ProjectEditorSmokeTimer.Stop()};return}
        try{
            $grids=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.DataGridView]}|Sort-Object{$_.Top})
            $configGrid=@($grids|Select-Object -First 1)
            $historyGrid=@($grids|Select-Object -Skip 1 -First 1)
            $textBoxes=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.TextBox]}|Sort-Object{$_.Top})
            $useButton=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.Button]-and[string]$_.Text-in@('使用选中会话','填入选中会话')}|Select-Object -First 1)
            $cancelButton=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.Button]-and$_.Text-eq'取消'}|Select-Object -First 1)
            $note=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.Label]-and[string]$_.Text-like'选择*会话*'}|Select-Object -First 1)
            if($configGrid.Count-ne1-or$historyGrid.Count-ne1-or$historyGrid[0].Rows.Count-lt1-or$textBoxes.Count-lt2-or$useButton.Count-ne1-or$cancelButton.Count-ne1){
                if((Get-Date)-gt$script:ProjectEditorSmokeDeadline){throw '新建项目窗口控件未能在自动化测试期限内完成初始化。'}
                return
            }
            if($note.Count-eq1-and($cancelButton[0].Bottom-gt$editor[0].ClientSize.Height-or$cancelButton[0].Top-lt$note[0].Bottom)){throw 'Project editor cancel button overlaps the note or is clipped.'}
            $historyGrid[0].Rows[0].Selected=$true;$historyGrid[0].CurrentCell=$historyGrid[0].Rows[0].Cells[0];$useButton[0].PerformClick()
            if($textBoxes[1].Text-ne[string]$script:ProjectEditorSmokeSession.working_directory-or$configGrid[0].Rows.Count-lt1-or[string]$configGrid[0].Rows[0].Cells['SessionId'].Value-ne[string]$script:ProjectEditorSmokeSession.session_id){throw 'Project editor did not apply the selected Codex session.'}
            $script:ProjectEditorSmokeTimer.Stop();$editor[0].DialogResult='Cancel';$editor[0].Close()
        }catch{$script:ProjectEditorSmokeError=$_.Exception.Message;$script:ProjectEditorSmokeTimer.Stop();$editor[0].DialogResult='Cancel';$editor[0].Close()}
    })
    try{$script:ProjectEditorSmokeTimer.Start();[void](Show-ProjectEditor)}finally{$script:ProjectEditorSmokeTimer.Stop();$script:ProjectEditorSmokeTimer.Dispose();$script:ProjectEditorSmokeTimer=$null}
    if($null-ne$script:ProjectEditorSmokeError){throw $script:ProjectEditorSmokeError}
}

function Invoke-ScheduleEditorSmokeTest {
    $script:ScheduleEditorSmokeFound=$false
    $script:ScheduleEditorSmokeError=$null
    $workflow=$script:CurrentWorkflow
    if($null-eq$workflow){throw 'Schedule dialog smoke test requires a current workflow.'}
    $originalScheduleMode=[string](Get-UiConfigValue $workflow 'ScheduleMode' 'Loop')
    $originalScheduleKind=[string](Get-UiConfigValue $workflow 'ScheduleKind' 'Interval')
    $originalScheduleTime=[string](Get-UiConfigValue $workflow 'ScheduleTime' '09:00:00')
    $workflow.ScheduleMode='Loop';$workflow.ScheduleKind='Daily';$workflow.ScheduleTime='08:12:34'
    $script:ScheduleEditorSmokeTimer=New-Object Windows.Forms.Timer
    $script:ScheduleEditorSmokeTimer.Interval=120
    $script:ScheduleEditorSmokeTimer.Add_Tick({
        $editor=@([Windows.Forms.Application]::OpenForms|Where-Object{$_.Text-like'定时配置 -*'}|Select-Object -Last 1)
        if($editor.Count-eq0){return}
        try{
            $modeBoxes=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.ComboBox]})
            $cancelButton=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.Button]-and$_.Text-eq'取消'}|Select-Object -First 1)
            $timeBoxes=@($editor[0].Controls|Where-Object{$_-is[Windows.Forms.TextBox]-and$_.Visible}|Sort-Object{$_.Top})
            if($modeBoxes.Count-lt2-or$modeBoxes[0].Items.Count-ne2-or$cancelButton.Count-ne1-or$timeBoxes.Count-lt1){throw 'Schedule dialog controls are incomplete.'}
            if([string]$timeBoxes[0].Text-ne'08:12:34'){throw ('Schedule dialog execution time was not initialized on first show: '+[string]$timeBoxes[0].Text)}
            $script:ScheduleEditorSmokeFound=$true
            $script:ScheduleEditorSmokeTimer.Stop()
            $cancelButton[0].PerformClick()
        }catch{
            $script:ScheduleEditorSmokeError=$_.Exception.Message
            $script:ScheduleEditorSmokeTimer.Stop()
            $editor[0].DialogResult='Cancel'
            $editor[0].Close()
        }
    })
    try{
        $script:ScheduleEditorSmokeTimer.Start()
        $script:ScheduleButton.PerformClick()
    }finally{
        $script:ScheduleEditorSmokeTimer.Stop()
        $script:ScheduleEditorSmokeTimer.Dispose()
        $script:ScheduleEditorSmokeTimer=$null
        $workflow.ScheduleMode=$originalScheduleMode;$workflow.ScheduleKind=$originalScheduleKind;$workflow.ScheduleTime=$originalScheduleTime
    }
    if($null-ne$script:ScheduleEditorSmokeError){throw $script:ScheduleEditorSmokeError}
    if(-not$script:ScheduleEditorSmokeFound){throw 'Schedule button did not open its dialog.'}
}

function Invoke-WorkflowUiSmokeTest {
    $testDirectory = Join-Path $env:TEMP ('PowerUI-WorkflowSmoke-' + $PID)
    $script:ApiPort = 20000 + ($PID % 10000)
    $script:DataDirectory = $testDirectory
    $script:WorkflowPath = Join-Path $testDirectory 'workflows.json'
    $script:ProjectPath = Join-Path $testDirectory 'projects.json'
    $script:SettingsPath = Join-Path $testDirectory 'settings.json'
    $script:LogDirectory = Join-Path $testDirectory 'logs'
    $script:LogPath = Join-Path $script:LogDirectory 'smoke.log'
    $script:WorkflowAiDirectory = Join-Path $testDirectory 'workflow-ai'
    $script:EmbeddedWorkflowSkillPath = Join-Path $script:WorkflowAiDirectory 'skills\workflow-manager'
    $script:GlobalSettings = New-DefaultGlobalSettings
    $script:GlobalSettings.CommonPrompts = @([bool]$false,'False','检查当前修改并给出风险','整理执行日志并给出下一步')
    $script:GlobalSettings = Normalize-GlobalSettings $script:GlobalSettings
    $smokeTreeSource=Join-Path $testDirectory 'src';$smokeTreeHeavy=Join-Path $testDirectory 'node_modules';[IO.Directory]::CreateDirectory($smokeTreeSource)|Out-Null;[IO.Directory]::CreateDirectory($smokeTreeHeavy)|Out-Null
    $smokeTreeTextFile=Join-Path $testDirectory 'tree-sample.ps1';[IO.File]::WriteAllText($smokeTreeTextFile,'Write-Output tree')
    [IO.File]::WriteAllText((Join-Path $smokeTreeSource 'child.py'),'print("child")')
    foreach($fileIndex in 1..105){[IO.File]::WriteAllText((Join-Path $smokeTreeHeavy ('package-'+$fileIndex.ToString('000')+'.js')),'x')}
    $smokeSessionDirectory=Join-Path $testDirectory 'sessions';[IO.Directory]::CreateDirectory($smokeSessionDirectory)|Out-Null
    $smokeSessionPath=Join-Path $smokeSessionDirectory 'rollout-smoke-session.jsonl'
    $smokeMeta=[pscustomobject]@{timestamp='2026-08-12T06:00:00Z';type='session_meta';payload=[pscustomobject]@{session_id='smoke-session';id='smoke-session';cwd=$testDirectory;source='test'}}
    $smokeUser=[pscustomobject]@{timestamp='2026-08-12T06:00:01Z';type='event_msg';payload=[pscustomobject]@{type='user_message';message='Smoke prompt'}}
    $smokeAssistant=[pscustomobject]@{timestamp='2026-08-12T06:00:02Z';type='event_msg';payload=[pscustomobject]@{type='agent_message';message='Smoke answer';phase='final'}}
    [IO.File]::WriteAllText($smokeSessionPath,(($smokeMeta|ConvertTo-Json -Depth 8 -Compress)+"`n"+($smokeUser|ConvertTo-Json -Depth 8 -Compress)+"`n"+($smokeAssistant|ConvertTo-Json -Depth 8 -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
    $script:CodexSessionsDirectory=$smokeSessionDirectory
    $script:CodexSessionCache=@([pscustomobject]@{time='2026-08-12T06:00:00Z';title='Smoke session';session_id='smoke-session';working_directory=$testDirectory;source='test';file=$smokeSessionPath;last_write_time='2026-08-12T06:00:02Z'})
    $script:CodexSessionCacheAt=Get-Date
    $smokeProject = New-Project 'Smoke project' $testDirectory 'smoke-session' 'gpt-5.4'
    $emptySessionProject = New-Project 'Empty session project' $testDirectory ''
    $smokeProject.UpdatedAt='2026-08-10T06:00:00Z'
    $emptySessionProject.UpdatedAt='2026-08-13T06:00:00Z'
    $script:Projects = @($smokeProject,$emptySessionProject)
    $script:Workflows = @((New-DefaultWorkflow), (New-DefaultWorkflow 'Project workflow A' ([string]$smokeProject.Id)), (New-DefaultWorkflow 'Project workflow B' ([string]$smokeProject.Id)))
    $script:SmokeError = $null
    $script:SmokeStage = 'initializing'
    $script:SmokeTimer = New-Object System.Windows.Forms.Timer
    $script:SmokeTimer.Interval = 1000
    $script:SmokeTimer.Add_Tick({
        $script:SmokeTimer.Stop()
        try {
            if ($script:ProjectSelector.Items.Count -ne 3 -or $script:ProjectSelector.SelectedIndex -ne 0) { throw 'Project selector was not initialized with the ungrouped item.' }
            if($script:MainForm.AutoScaleMode-ne[Windows.Forms.AutoScaleMode]::Dpi-or-not$script:ProjectSelector.IntegralHeight-or$script:ProjectSelector.DropDownHeight-lt($script:ProjectSelector.Items.Count*$script:ProjectSelector.ItemHeight)-or$script:ProjectSelector.DropDownWidth-lt300){throw ('DPI/project selector layout invalid: mode={0}; integral={1}; height={2}; expectedHeight={3}; width={4}; items={5}; itemHeight={6}' -f $script:MainForm.AutoScaleMode,$script:ProjectSelector.IntegralHeight,$script:ProjectSelector.DropDownHeight,($script:ProjectSelector.Items.Count*$script:ProjectSelector.ItemHeight),$script:ProjectSelector.DropDownWidth,$script:ProjectSelector.Items.Count,$script:ProjectSelector.ItemHeight)}
            if($script:WorkflowList.DrawMode-ne[Windows.Forms.DrawMode]::OwnerDrawFixed-or$script:WorkflowList.ItemHeight-lt40-or$script:WorkflowList.Font.Name-ne'Microsoft YaHei UI'-or$script:WorkflowList.BorderStyle-ne[Windows.Forms.BorderStyle]::None){throw 'Workflow task list styling is invalid.'}
            if($script:ProjectSelector.DrawMode-ne[Windows.Forms.DrawMode]::OwnerDrawFixed-or$script:ProjectSelector.ItemHeight-lt30-or$script:ProjectSelector.Font.Name-ne'Microsoft YaHei UI'-or$null-eq$script:ProjectSelectorFrame){throw 'Project selector styling is invalid.'}
            if($script:WorkflowNameBox.BorderStyle-ne[Windows.Forms.BorderStyle]::None-or$script:WorkflowNameBox.Font.Name-ne'Microsoft YaHei UI'-or$null-eq$script:WorkflowNameFrame){throw 'Workflow name input styling is invalid.'}
            if ($script:WorkflowList.Items.Count -ne 1 -or [string]$script:WorkflowList.Items[0].ProjectId -ne '') { throw 'Ungrouped workflow filter is invalid.' }
            if ($script:ProjectEditButton.Enabled -or $script:ProjectDeleteButton.Enabled -or $script:ProjectOpenButton.Enabled -or $script:ProjectChatButton.Enabled) { throw 'Project-only actions should be disabled for ungrouped workflows.' }
            $smokeProjectSelectorIndex=-1;for($projectIndex=0;$projectIndex-lt$script:ProjectSelector.Items.Count;$projectIndex++){if([string]$script:ProjectSelector.Items[$projectIndex].Id-eq[string]$smokeProject.Id){$smokeProjectSelectorIndex=$projectIndex;break}}
            if($smokeProjectSelectorIndex-lt0){throw 'Smoke project is missing from the selector.'}
            $script:ProjectSelector.SelectedIndex = $smokeProjectSelectorIndex; [Windows.Forms.Application]::DoEvents()
            if ($null -eq $script:CurrentProject -or [string]$script:CurrentProject.Id -ne [string]$smokeProject.Id -or $script:WorkflowList.Items.Count -ne 2 -or [string]$script:WorkflowList.Items[0].ProjectId -ne [string]$smokeProject.Id) { throw 'Project workflow filter is invalid.' }
            if (-not $script:ProjectEditButton.Enabled -or -not $script:ProjectOpenButton.Enabled -or -not $script:ProjectChatButton.Enabled) { throw 'Project actions were not enabled for the selected project.' }
            if(-not$script:ProjectInfoLabel.AutoEllipsis-or-not$script:ProjectSessionLabel.AutoEllipsis-or$script:ProjectSessionLabel.Text-notlike'Codex：*'-or$script:ProjectSessionLabel.Text-notlike'*模型：gpt-5.4*'){throw 'Project Codex session/model summary is not ellipsized or readable.'}
            Show-SessionManagerPage
            [Windows.Forms.Application]::DoEvents()
            if(-not$script:SessionManagerPanel.Visible-or$script:Canvas.Visible-or$script:WorkflowSettingsPanel.Visible-or$script:CodexConversationPanel.Visible-or$script:SessionManagerGrid.Columns.Count-ne7-or$script:SessionManagerGrid.Rows.Count-ne2){throw 'Session manager page, columns, or project rows are invalid.'}
            $completedRow=@($script:SessionManagerGrid.Rows|Where-Object{[string](Get-UiConfigValue $_.Tag 'ProjectId' '')-eq[string]$smokeProject.Id}|Select-Object -First 1)
            $uncreatedRow=@($script:SessionManagerGrid.Rows|Where-Object{[string](Get-UiConfigValue $_.Tag 'ProjectId' '')-eq[string]$emptySessionProject.Id}|Select-Object -First 1)
            if($completedRow.Count-ne1-or[string]$completedRow[0].Cells[1].Value-ne'已完成'-or$uncreatedRow.Count-ne1-or[string]$uncreatedRow[0].Cells[1].Value-ne'未创建'){throw 'Session manager completed/uncreated status is invalid.'}
            if([string](Get-UiConfigValue $script:SessionManagerGrid.Rows[0].Tag 'ProjectId' '')-ne[string]$emptySessionProject.Id-or[string](Get-UiConfigValue $script:SessionManagerGrid.Rows[1].Tag 'ProjectId' '')-ne[string]$smokeProject.Id){throw 'Session manager is not sorted by descending update time.'}
            $preservedProjectTime=[string]$smokeProject.UpdatedAt
            Save-Projects
            if([string]$smokeProject.UpdatedAt-ne$preservedProjectTime){throw 'Saving projects unexpectedly changed an unrelated project update time.'}
            $busySessionRecord=[pscustomobject]@{WorkflowId='session-manager-busy';WorkflowName='会话占用任务';ActiveCodexSessionId='smoke-session'};$script:RunningJobs[[string]$busySessionRecord.WorkflowId]=$busySessionRecord
            try{Refresh-SessionManagerView -Force;if([string]$completedRow[0].Cells[1].Value-ne'工作流调用中'){throw 'Session manager workflow-busy status is invalid.'}}finally{$script:RunningJobs.Remove([string]$busySessionRecord.WorkflowId)}
            $conversationStateProcess=New-Object Diagnostics.Process;$conversationStateProcess.StartInfo.FileName=$env:ComSpec;$conversationStateProcess.StartInfo.Arguments='/d /c ping 127.0.0.1 -n 4 > nul';$conversationStateProcess.StartInfo.UseShellExecute=$false;$conversationStateProcess.StartInfo.CreateNoWindow=$true;[void]$conversationStateProcess.Start()
            $conversationStateKey=Get-CodexConversationProcessKey 'Project' ([string]$smokeProject.Id) 'smoke-session';$script:CodexConversationProcesses[$conversationStateKey]=[pscustomobject]@{Key=$conversationStateKey;Process=$conversationStateProcess;Mode='Project';ProjectId=[string]$smokeProject.Id;SessionId='smoke-session';InitialSessionId='smoke-session'}
            try{Refresh-SessionManagerView -Force;if([string]$completedRow[0].Cells[1].Value-ne'对话进行中'){throw 'Session manager active-conversation status is invalid.'}}finally{try{if(-not$conversationStateProcess.HasExited){$conversationStateProcess.Kill()}}catch{};try{$conversationStateProcess.Dispose()}catch{};$script:CodexConversationProcesses.Remove($conversationStateKey)}
            $completedRow[0].Selected=$true;$script:SessionManagerGrid.CurrentCell=$completedRow[0].Cells[0];Open-SelectedManagedSession;[Windows.Forms.Application]::DoEvents()
            if(-not$script:CodexConversationPanel.Visible-or$script:CodexConversationProjectId-ne[string]$smokeProject.Id-or$script:CodexConversationSessionId-ne'smoke-session'-or[string]$script:CurrentProject.Id-ne[string]$smokeProject.Id){throw 'Session manager did not jump to the selected project conversation.'}
            Show-ProjectConversation
            [Windows.Forms.Application]::DoEvents()
            if (-not $script:CodexConversationPanel.Visible -or $script:Canvas.Visible -or $script:WorkflowSettingsPanel.Visible) { throw "Project Codex conversation view did not open: conversation=$($script:CodexConversationPanel.Visible), canvas=$($script:Canvas.Visible), settings=$($script:WorkflowSettingsPanel.Visible), parent=$($script:CodexConversationPanel.Parent.Visible)." }
            if($script:CodexConversationOutput.Text-notlike'*Smoke prompt*'-or$script:CodexConversationOutput.Text-notlike'*Smoke answer*'-or$script:CodexConversationStatus.Text-notlike'已恢复历史会话*'){throw 'Project conversation did not automatically load the resumed session history.'}
            $reuseControlCount=$script:CodexConversationOutput.Controls.Count;$reuseTranscript=[string]$script:CodexConversationOutput.Text;$reusePrimarySession=Get-ProjectPrimaryCodexSession $smokeProject
            Show-RunningTasksPage;[Windows.Forms.Application]::DoEvents()
            if(-not$script:RunningTasksPanel.Visible-or$script:CodexConversationPanel.Visible){throw 'Running task page did not hide the active conversation before reuse testing.'}
            Show-ProjectConversation -SessionId 'smoke-session' -UseSelectedSession -SelectedSession $reusePrimarySession;[Windows.Forms.Application]::DoEvents()
            if(-not$script:CodexConversationPanel.Visible-or$script:RunningTasksPanel.Visible-or$script:CodexConversationOutput.Controls.Count-ne$reuseControlCount-or[string]$script:CodexConversationOutput.Text-ne$reuseTranscript){throw 'Reopening the same project conversation rebuilt its rendered history.'}
            $smokePrimarySession=Get-ProjectPrimaryCodexSession $smokeProject
            $smokePendingSession=[pscustomobject]@{SessionId='';CodexModel='gpt-pending';Description='待创建提问'}
            $smokeQuestionSession=[pscustomobject]@{SessionId='smoke-question-session';CodexModel='gpt-question';Description='临时提问'}
            Set-ProjectCodexSessions $smokeProject @($smokePrimarySession,$smokePendingSession,$smokeQuestionSession)
             Show-ProjectConversation 'smoke-session';[Windows.Forms.Application]::DoEvents()
             if($null-eq$script:CodexConversationSessionSelector-or-not$script:CodexConversationSessionSelector.Visible-or$script:CodexConversationSessionSelector.Items.Count-ne3-or[string]$script:CodexConversationSessionSelector.Items[1].Description-ne'待创建提问'-or[string]$script:CodexConversationSessionSelector.Items[2].Description-ne'临时提问'){throw 'Project conversation multi-session selector was not populated.'}
             if($script:CodexConversationTitle.BackColor.A-ne0-or$script:CodexConversationTitle.Parent-ne$script:CodexConversationHeader-or$script:CodexConversationSessionSelector.Top-le$script:CodexConversationTitle.Bottom-or$script:CodexConversationSessionSelector.Left-ne$script:CodexConversationTitle.Left-or$script:CodexConversationTitle.Right-ge$script:CodexConversationPreviousUserButton.Left){throw ('Project conversation title/selector layout is invalid: headerWidth={0}; titleBack={1}; title={2},{3},{4},{5}; selector={6},{7},{8},{9}; previous={10},{11}; stop={12},{13}; reload={14},{15}; files={16},{17}; back={18},{19}; terminal={20},{21}'-f$script:CodexConversationHeader.ClientSize.Width,$script:CodexConversationTitle.BackColor.ToArgb(),$script:CodexConversationTitle.Left,$script:CodexConversationTitle.Top,$script:CodexConversationTitle.Right,$script:CodexConversationTitle.Bottom,$script:CodexConversationSessionSelector.Left,$script:CodexConversationSessionSelector.Top,$script:CodexConversationSessionSelector.Right,$script:CodexConversationSessionSelector.Bottom,$script:CodexConversationPreviousUserButton.Left,$script:CodexConversationPreviousUserButton.Right,$script:CodexConversationStopButton.Left,$script:CodexConversationStopButton.Right,$script:CodexConversationReloadButton.Left,$script:CodexConversationReloadButton.Right,$script:CodexConversationFileTreeToggleButton.Left,$script:CodexConversationFileTreeToggleButton.Right,$script:CodexConversationBackButton.Left,$script:CodexConversationBackButton.Right,$script:CodexConversationTerminalButton.Left,$script:CodexConversationTerminalButton.Right)}
             if($script:CodexConversationSessionSelector.DrawMode-ne[Windows.Forms.DrawMode]::OwnerDrawFixed-or$script:CodexConversationSessionSelector.DropDownHeight-lt200){throw 'Project conversation session selector styling is invalid.'}
            Show-SessionManagerPage;[Windows.Forms.Application]::DoEvents();Refresh-SessionManagerView -Force
            $pendingManagedRow=@($script:SessionManagerGrid.Rows|Where-Object{[string](Get-UiConfigValue $_.Tag 'ProjectId' '')-eq[string]$smokeProject.Id-and[string](Get-UiConfigValue $_.Tag 'Description' '')-eq'待创建提问'}|Select-Object -First 1)
            if($pendingManagedRow.Count-ne1){throw 'Session manager did not list the configured uncreated auxiliary session.'}
            $pendingManagedRow[0].Selected=$true;$script:SessionManagerGrid.CurrentCell=$pendingManagedRow[0].Cells[0];Open-SelectedManagedSession;[Windows.Forms.Application]::DoEvents()
            if(-not$script:CodexConversationPanel.Visible-or-not[string]::IsNullOrWhiteSpace($script:CodexConversationSessionId)-or$script:CodexConversationSessionDescription-ne'待创建提问'-or$script:CodexConversationTitle.Text-notlike'*待创建提问*'-or$script:CodexConversationSessionSelector.SelectedIndex-ne1){throw 'Session manager did not open the selected uncreated session description.'}
            $script:CodexConversationSessionSelector.SelectedIndex=2;[Windows.Forms.Application]::DoEvents()
            if($script:CodexConversationSessionId-ne'smoke-question-session'-or$script:CodexConversationSessionDescription-ne'临时提问'-or$script:CodexConversationTitle.Text-notlike'*临时提问*'){throw 'Project conversation did not switch to the selected auxiliary session.'}
            $script:CodexConversationSessionSelector.SelectedIndex=0;[Windows.Forms.Application]::DoEvents()
            if($script:CodexConversationSessionId-ne'smoke-session'-or$script:CodexConversationOutput.Text-notlike'*Smoke answer*'){throw 'Project conversation did not switch back to the primary session.'}
            $script:SmokeStage='conversation-file-tree'
            if($null-eq$script:CodexConversationSplit-or$null-eq$script:CodexConversationFileTree-or$script:CodexConversationFileTreeDirectory-ne$testDirectory-or$script:CodexConversationFileTreeContextMenu.Items.Count-ne9){throw 'Conversation file-tree panel was not initialized for the project directory.'}
            $fileTreeDeadline=(Get-Date).AddSeconds(5)
            while($script:CodexConversationFileTree.Nodes.Count-gt0-and[bool]$script:CodexConversationFileTree.Nodes[0].Tag.Loading-and(Get-Date)-lt$fileTreeDeadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20}
            if($script:CodexConversationFileTree.Nodes.Count-ne1){throw 'Conversation file-tree root is missing.'}
            $fileTreeRoot=$script:CodexConversationFileTree.Nodes[0]
            if([bool]$fileTreeRoot.Tag.Loading-or-not[bool]$fileTreeRoot.Tag.Loaded-or-not$fileTreeRoot.IsExpanded){throw 'Conversation file-tree root did not finish its asynchronous first-level load.'}
            $sourceTreeNode=@($fileTreeRoot.Nodes|Where-Object{$null-ne$_.Tag-and[string]$_.Tag.Path-eq$smokeTreeSource}|Select-Object -First 1)
            $heavyTreeNode=@($fileTreeRoot.Nodes|Where-Object{$null-ne$_.Tag-and[string]$_.Tag.Path-eq$smokeTreeHeavy}|Select-Object -First 1)
            $textTreeNode=@($fileTreeRoot.Nodes|Where-Object{$null-ne$_.Tag-and[string]$_.Tag.Path-eq$smokeTreeTextFile}|Select-Object -First 1)
            if($sourceTreeNode.Count-ne1-or[bool]$sourceTreeNode[0].Tag.Loaded-or$sourceTreeNode[0].Nodes.Count-ne1-or$heavyTreeNode.Count-ne1-or$textTreeNode.Count-ne1){throw 'Conversation file-tree did not preserve lazy child placeholders or list the root file.'}
            $heavyTreeNode[0].Expand();$fileTreeDeadline=(Get-Date).AddSeconds(5)
            while([bool]$heavyTreeNode[0].Tag.Loading-and(Get-Date)-lt$fileTreeDeadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20}
            if(-not[bool]$heavyTreeNode[0].Tag.Loaded-or@($heavyTreeNode[0].Nodes|Where-Object{[string]$_.Tag.Kind-eq'File'}).Count-ne100-or@($heavyTreeNode[0].Nodes|Where-Object{$_.Text-like'… 内容较多*'}).Count-ne1){throw 'Heavy package directory was not lazily capped with a truncation notice.'}
            $script:CodexConversationInput.Text='前缀 后缀';$script:CodexConversationInput.SelectionStart=3;$script:CodexConversationInput.SelectionLength=0
            if(-not(Insert-CodexConversationFileTreePath $smokeTreeTextFile)-or$script:CodexConversationInput.Text-ne('前缀 '+$smokeTreeTextFile+'后缀')){throw 'File-tree path was not inserted at the conversation caret.'}
            $script:CodexConversationInput.Clear()
            $treeMenuTexts=@($script:CodexConversationFileTreeContextMenu.Items|ForEach-Object{$_.Text})
            if($treeMenuTexts-notcontains'添加路径到对话'-or$treeMenuTexts-notcontains'打开'-or$treeMenuTexts-notcontains'定位并选中'-or$treeMenuTexts-notcontains'复制'-or$treeMenuTexts-notcontains'粘贴'-or$treeMenuTexts-notcontains'删除'-or$treeMenuTexts-notcontains'在 pwd 中打开'-or$treeMenuTexts-notcontains'在 PowerShell 中打开'-or@($treeMenuTexts|Where-Object{$_-eq'打开目录'}).Count-ne0){throw 'Conversation file-tree context actions are missing or duplicated.'}
            if((Get-CodexConversationFileTreeWorkingDirectory $smokeTreeTextFile)-ne$testDirectory-or(Get-CodexConversationFileTreeWorkingDirectory $smokeTreeSource)-ne$smokeTreeSource){throw 'Conversation file-tree terminal working-directory resolution is invalid.'}
            $treeLaunchSpec=Open-CodexConversationFileTreeItem $smokeTreeTextFile -ReturnLaunchSpec
            if($null-eq$treeLaunchSpec-or$treeLaunchSpec.Kind-ne'TextFile'-or[string]$treeLaunchSpec.Arguments[0]-ne$smokeTreeTextFile){throw 'Conversation file-tree text opening specification is invalid.'}
            $treeLocateSpec=Locate-CodexConversationFileTreeItem $smokeTreeTextFile -ReturnLaunchSpec
            if($null-eq$treeLocateSpec-or[string]$treeLocateSpec.Kind-ne'File'-or[string]$treeLocateSpec.FilePath-ne'explorer.exe'-or[string]$treeLocateSpec.Arguments[0]-notlike'/select,*'){throw ('Conversation file-tree file locate specification is invalid: kind='+[string]$treeLocateSpec.Kind+'; filePath='+[string]$treeLocateSpec.FilePath+'; argument='+[string]$treeLocateSpec.Arguments[0])}
            $treePasteDestination=Get-CodexConversationFileTreePasteDestination $testDirectory $smokeTreeTextFile
            if([string]::Equals([string]$treePasteDestination,[string]$smokeTreeTextFile,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($treePasteDestination)-notlike'*副本*'){throw 'Conversation file-tree paste destination resolution is invalid.'}
            $script:ConversationNoChangeLayoutCount=0
            $noChangeLayoutHandler={param($sender,$eventArgs);$script:ConversationNoChangeLayoutCount++}
            $script:CodexConversationOutput.Add_Layout($noChangeLayoutHandler)
            $noChangeControls=$script:CodexConversationOutput.Controls.Count;$noChangeDisplayHeight=$script:CodexConversationOutput.DisplayRectangle.Height;$noChangeScrollY=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y);$noChangeTranscript=[string]$script:CodexConversationOutput.Text
            try{foreach($refreshIndex in 1..120){Load-CodexConversationSession 'smoke-session' 'Smoke project' -Incremental}}finally{$script:CodexConversationOutput.Remove_Layout($noChangeLayoutHandler)}
            if($script:ConversationNoChangeLayoutCount-ne0-or$script:CodexConversationOutput.Controls.Count-ne$noChangeControls-or$script:CodexConversationOutput.DisplayRectangle.Height-ne$noChangeDisplayHeight-or[Math]::Abs(([Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y))-$noChangeScrollY)-gt1-or[string]$script:CodexConversationOutput.Text-ne$noChangeTranscript){throw ('No-change conversation refresh mutated layout or scroll state: layouts='+$script:ConversationNoChangeLayoutCount)}
            foreach($scrollRequestIndex in 1..80){Schedule-CodexConversationScrollToBottom}
            if(-not$script:CodexConversationScrollPending){throw 'Conversation scroll request was not queued.'}
            $script:CodexConversationScrollGeneration++
            $script:CodexConversationScrollPending=$false
            $script:SmokeStage='conversation-markdown'
            Add-CodexConversationMessage 'user' ('请检查 **这个文件**：[sample.py]('+(Join-Path $testDirectory 'sample.py')+':203)。这是一段用于验证气泡最大宽度、跨行换行和内部左对齐的较长消息，文本不应该只在每一行后面形成零散底色。')
            Add-CodexConversationMessage 'assistant' "## 检查结果`r`n- 已定位`r`n> Ctrl + 单击链接可打开`r`nhttps://example.com`r`n`r`n"
            if(@($script:CodexConversationBubbleRecords|Where-Object{$_.TextBox.DetectUrls}).Count-gt0-or$script:CodexConversationLinks.Count-lt2-or$script:CodexConversationOutput.Text-like'*## 检查结果*'){throw 'Lightweight Markdown or custom link rendering is invalid.'}
            if(@($script:CodexConversationBubbleRecords|Where-Object{$_.TextBox.Text.EndsWith("`r")-or$_.TextBox.Text.EndsWith("`n")}).Count-gt0){throw 'Conversation bubbles retained a trailing blank line.'}
            $resolvedCodeLink=Resolve-CodexConversationLinkTarget 'D:/200mergeBackup/HardwareConfigurationForm/BACnetMSTPMasterScanImportDialog.py:203'
            $resolvedLeadingSlashLink=Resolve-CodexConversationLinkTarget '/D:/桌面/fun/powerUI/workflow/WorkflowManager.ps1'
            $resolvedUrlLink=Resolve-CodexConversationLinkTarget 'https://example.com/docs'
            $conversationLocationSpec=Open-CodexConversationLinkLocation $smokeTreeTextFile -ReturnLaunchSpec
            $conversationLinkMenu=Ensure-CodexConversationLinkContextMenu
            $locationArgument = if($null -ne $conversationLocationSpec -and @($conversationLocationSpec.Arguments).Count -gt 0){[string]$conversationLocationSpec.Arguments[0]}else{''}
            $linkLocationValid = $null -ne $conversationLocationSpec -and [string]$conversationLocationSpec.Kind -eq 'File' -and [string]$conversationLocationSpec.FilePath -eq 'explorer.exe' -and $locationArgument -like '/select,*'
            $linkMenuValid = $null -ne $conversationLinkMenu -and @($conversationLinkMenu.Items | Where-Object { [string]$_.Text -eq '打开位置' }).Count -eq 1
            if([string]$resolvedCodeLink.Kind -ne 'TextDocument' -or [int]$resolvedCodeLink.Line -ne 203 -or [string]$resolvedLeadingSlashLink.Kind -ne 'TextDocument' -or [string]$resolvedLeadingSlashLink.Target -notmatch '^[A-Za-z]:\\' -or [string]$resolvedUrlLink.Kind -ne 'Url' -or -not $linkLocationValid -or -not $linkMenuValid){throw 'Conversation link target or file-location context action is invalid.'}
            if($null-eq$script:CodexConversationInputFrame-or$script:CodexConversationInput.BorderStyle-ne[Windows.Forms.BorderStyle]::None-or$script:CodexConversationInput.Font.Name-ne'Microsoft YaHei UI'){throw 'Conversation input styling was not applied.'}
            $previewFixturePath=Join-Path $testDirectory 'preview-fixture.png';$previewFixture=New-Object Drawing.Bitmap -ArgumentList 12,8;try{$previewFixture.Save($previewFixturePath,[Drawing.Imaging.ImageFormat]::Png)}finally{$previewFixture.Dispose()}
            if(-not(Import-CodexConversationImageFile $previewFixturePath)){throw 'Conversation image fixture could not be imported.'}
            [Windows.Forms.Application]::DoEvents()
            $attachmentCard=$script:CodexConversationAttachmentPreview.Controls[0];$composerMinimumWithImage=Get-CodexConversationComposerMinimumHeight
            if($script:CodexConversationPendingImages.Count-ne1-or$script:CodexConversationAttachmentPreview.Controls.Count-ne1-or-not$script:CodexConversationAttachmentPreview.Visible-or$script:CodexConversationInputSurface.RowStyles[1].Height-lt$attachmentCard.Height-or$script:CodexConversationComposerRowStyle.Height-lt$composerMinimumWithImage-or$script:CodexConversationAttachButton.Text-notlike'粘贴图片 (1)'-or$script:CodexConversationAttachButton.Bottom-gt$script:CodexConversationActions.ClientSize.Height-or$script:CodexConversationClearAttachmentsButton.Bottom-gt$script:CodexConversationActions.ClientSize.Height){throw ('Conversation image attachment preview layout is invalid: previewRow='+$script:CodexConversationInputSurface.RowStyles[1].Height+'; card='+$attachmentCard.Height+'; rowStyle='+$script:CodexConversationComposerRowStyle.Height+'; minimum='+$composerMinimumWithImage+'; composer='+$script:CodexConversationComposer.Bounds+'; composerLayout='+$script:CodexConversationComposerLayout.Bounds+'; attach='+$script:CodexConversationAttachButton.Bounds+'; clear='+$script:CodexConversationClearAttachmentsButton.Bounds+'; actions='+$script:CodexConversationActions.ClientSize+'.')}
            Clear-CodexConversationPendingImages
            $composerMinimumWithoutImage=Get-CodexConversationComposerMinimumHeight
            if($script:CodexConversationPendingImages.Count-ne0-or$script:CodexConversationAttachmentPreview.Controls.Count-ne0-or$script:CodexConversationAttachmentPreview.Visible-or[Math]::Abs($script:CodexConversationComposerRowStyle.Height-$composerMinimumWithoutImage)-gt2-or$script:CodexConversationClearAttachmentsButton.Enabled){throw ('Conversation image attachment clear action did not restore the composer: pending='+$script:CodexConversationPendingImages.Count+'; cards='+$script:CodexConversationAttachmentPreview.Controls.Count+'; visible='+$script:CodexConversationAttachmentPreview.Visible+'; rowHeight='+$script:CodexConversationComposerRowStyle.Height+'; minimum='+$composerMinimumWithoutImage+'; clearEnabled='+$script:CodexConversationClearAttachmentsButton.Enabled+'; actionBounds='+$script:CodexConversationActions.Bounds+'.')}
            $bubbleCountBeforeTransientFilter=$script:CodexConversationBubbleRecords.Count
            Add-CodexConversationMessage 'user' 'Warning: apply_patch was requested via shell. Use the apply_patch tool instead of exec_command.'
            Add-CodexConversationMessage 'assistant' "诊断信息：`r`n测试 stderr"
            if($script:CodexConversationBubbleRecords.Count-ne$bubbleCountBeforeTransientFilter){throw 'Synthetic warning or diagnostic text was rendered as a conversation bubble.'}
            if($script:CodexConversationUserMessagePositions.Count-ne2){throw 'User-message navigation state was not created.'}
            $latestUserRecord=$script:CodexConversationUserMessagePositions[1]
            $firstUserRecord=$script:CodexConversationUserMessagePositions[0]
            $latestUserRecord.TextBox.SelectionStart=0;$latestUserRecord.TextBox.SelectionLength=0
            if($latestUserRecord.TextBox.TabStop-or$null-eq$script:CodexConversationComposerLayout-or$null-eq$script:CodexConversationActions){throw 'Conversation text selection or composer container behavior is invalid.'}
            $oldConversationColors=@{Surface=[string]$script:GlobalSettings.ConversationSurfaceColor;User=[string]$script:GlobalSettings.ConversationUserBubbleColor;Assistant=[string]$script:GlobalSettings.ConversationAssistantBubbleColor;InputBackground=[string]$script:GlobalSettings.ConversationInputBackgroundColor}
            try{
                $script:GlobalSettings.ConversationSurfaceColor='#E2E8F0';$script:GlobalSettings.ConversationUserBubbleColor='#FDE68A';$script:GlobalSettings.ConversationAssistantBubbleColor='#ECFCCB';$script:GlobalSettings.ConversationInputBackgroundColor='#FFF7ED';Apply-CodexConversationPalette;$customPalette=Get-CodexConversationPalette
                $latestUserRecord.TextBox.SelectAll();$userSelectionBackColor=$latestUserRecord.TextBox.SelectionBackColor
                if($script:CodexConversationHeader.BackColor.ToArgb()-ne$customPalette.Surface.ToArgb()-or$script:CodexConversationComposer.BackColor.ToArgb()-ne$customPalette.Surface.ToArgb()-or$script:CodexConversationComposerLayout.BackColor.ToArgb()-ne$customPalette.Surface.ToArgb()-or$script:CodexConversationActions.BackColor.ToArgb()-ne$customPalette.Surface.ToArgb()-or$script:CodexConversationInputSurface.BackColor.ToArgb()-ne$customPalette.InputBackground.ToArgb()-or$latestUserRecord.Bubble.FillColor.ToArgb()-ne$customPalette.UserBubble.ToArgb()-or$userSelectionBackColor.ToArgb()-ne$customPalette.UserBubble.ToArgb()){throw 'Conversation palette did not cover the page containers and formatted message backgrounds.'}
            }finally{$script:GlobalSettings.ConversationSurfaceColor=$oldConversationColors.Surface;$script:GlobalSettings.ConversationUserBubbleColor=$oldConversationColors.User;$script:GlobalSettings.ConversationAssistantBubbleColor=$oldConversationColors.Assistant;$script:GlobalSettings.ConversationInputBackgroundColor=$oldConversationColors.InputBackground;Apply-CodexConversationPalette}
            $palette=Get-CodexConversationPalette
            if($latestUserRecord.Bubble.Right-lt$latestUserRecord.Row.Width-8-or$latestUserRecord.TextBox.SelectionAlignment-ne[Windows.Forms.HorizontalAlignment]::Left-or$latestUserRecord.Bubble.FillColor.ToArgb()-ne$palette.UserBubble.ToArgb()-or$latestUserRecord.TextBox.Height-le($latestUserRecord.TextBox.Font.Height*2)){
                throw ('User bubble is not right aligned, internally left aligned, colored, or wrapped across lines. rowWidth={0}; bubbleLeft={1}; bubbleWidth={2}; bubbleRight={3}; alignment={4}; fill={5}; expectedFill={6}; textHeight={7}; fontHeight={8}' -f $latestUserRecord.Row.Width,$latestUserRecord.Bubble.Left,$latestUserRecord.Bubble.Width,$latestUserRecord.Bubble.Right,$latestUserRecord.TextBox.SelectionAlignment,$latestUserRecord.Bubble.FillColor.ToArgb(),$palette.UserBubble.ToArgb(),$latestUserRecord.TextBox.Height,$latestUserRecord.TextBox.Font.Height)
            }
            $assistantRecordCountBefore=@($script:CodexConversationBubbleRecords|Where-Object{[string]$_.Role-eq'assistant'}).Count
            $assistantRecordBefore=$script:CodexConversationCurrentBubble
            Add-CodexConversationMessage 'assistant' '连续回复应聚合在同一个气泡中。' '2026-08-12T06:05:00Z'
            $assistantRecordCountAfter=@($script:CodexConversationBubbleRecords|Where-Object{[string]$_.Role-eq'assistant'}).Count
            $separatorPosition=$assistantRecordBefore.TextBox.Text.LastIndexOf('┈')
            if($assistantRecordCountAfter-ne$assistantRecordCountBefore-or-not[object]::ReferenceEquals($assistantRecordBefore,$script:CodexConversationCurrentBubble)-or$separatorPosition-lt0){throw 'Consecutive Codex replies were not merged into the same bubble.'}
            $assistantRecordBefore.TextBox.SelectionStart=$separatorPosition;$assistantRecordBefore.TextBox.SelectionLength=1
            if($null-eq$assistantRecordBefore.TextBox.SelectionFont-or$assistantRecordBefore.TextBox.SelectionFont.Size-ge8){throw 'Consecutive Codex reply time separator is not rendered in a compact font.'}
            [WorkflowNativeMethods]::ScrollRichTextToTop($assistantRecordBefore.TextBox)
            $assistantLastCharacterIndex=$assistantRecordBefore.TextBox.TextLength-1
            $assistantLastCharacterPosition=$assistantRecordBefore.TextBox.GetPositionFromCharIndex($assistantLastCharacterIndex)
            $assistantRecordBefore.TextBox.SelectionStart=$assistantLastCharacterIndex;$assistantRecordBefore.TextBox.SelectionLength=1
            $assistantLastFontHeight=if($null-ne$assistantRecordBefore.TextBox.SelectionFont){$assistantRecordBefore.TextBox.SelectionFont.Height}else{$assistantRecordBefore.TextBox.Font.Height}
            if($assistantRecordBefore.TextBox.Height-lt($assistantLastCharacterPosition.Y+$assistantLastFontHeight+6)){throw 'Conversation bubble height does not include the final text/time line.'}
            $assertConversationNavigation={
                param($record,[string]$label)
                [Windows.Forms.Application]::DoEvents()
                if(-not$record.TextBox.ContainsFocus){throw ('Previous-user arrow did not focus '+$label+'.')}
                $navigationCurrentY=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y)
                $navigationLogicalTop=$navigationCurrentY+[int]$record.Row.Top
                $navigationMaximum=[Math]::Max(0,$script:CodexConversationOutput.DisplayRectangle.Height-$script:CodexConversationOutput.ClientSize.Height)
                $navigationExpectedY=[Math]::Min($navigationMaximum,[Math]::Max(0,$navigationLogicalTop-10))
                $viewportTop=$script:CodexConversationOutput.PointToScreen([Drawing.Point]::Empty).Y
                $viewportBottom=$viewportTop+$script:CodexConversationOutput.ClientSize.Height
                $recordTop=$record.Row.PointToScreen([Drawing.Point]::Empty).Y
                $recordBottom=$recordTop+$record.Row.Height
                if([Math]::Abs($navigationCurrentY-$navigationExpectedY)-gt4-or$recordBottom-le$viewportTop-or$recordTop-ge$viewportBottom){throw ('Previous-user arrow did not explicitly position '+$label+' in the viewport.')}
            }
            $script:CodexConversationPreviousUserButton.PerformClick();& $assertConversationNavigation $latestUserRecord 'the latest user message'
            $script:CodexConversationPreviousUserButton.PerformClick();& $assertConversationNavigation $firstUserRecord 'the earlier user message'
            $script:CodexConversationPreviousUserButton.PerformClick();& $assertConversationNavigation $firstUserRecord 'the first user message'
            if($null-eq$script:CodexConversationSearchFrame-or$null-eq$script:CodexConversationSearchBox-or$script:CodexConversationSearchFrame.Right+8-gt$script:CodexConversationStatus.Left){throw 'Conversation search box is missing or overlaps the status text.'}
            Add-CodexConversationMessage 'user' '查找回归一' '2026-08-12T06:06:00Z';$searchUserRecord=$script:CodexConversationCurrentBubble
            Add-CodexConversationMessage 'assistant' '查找回归二' '2026-08-12T06:07:00Z';$searchAssistantRecord=$script:CodexConversationCurrentBubble
            $script:CodexConversationSearchBox.Text='查找回归';[void](Find-PreviousCodexConversationText);$firstSearchRecord=$script:CodexConversationSearchSelectedRecord
            if(-not[object]::ReferenceEquals($firstSearchRecord,$searchAssistantRecord)-or$script:CodexConversationSearchIndex-ne0-or-not$script:CodexConversationSearchBox.Focused){throw 'Conversation search did not start from the latest match.'}
            [void](Find-PreviousCodexConversationText);$secondSearchRecord=$script:CodexConversationSearchSelectedRecord
            if(-not[object]::ReferenceEquals($secondSearchRecord,$searchUserRecord)-or$script:CodexConversationSearchIndex-ne1){throw 'Conversation search did not continue from bottom to top.'}
            Reset-CodexConversationSearchState -ClearText
            $script:SmokeStage='conversation-vertical-layout'
            $originalWindowSize=$script:MainForm.Size
            $script:MainForm.Size=$script:MainForm.MinimumSize
            [Windows.Forms.Application]::DoEvents()
            if($null-eq$script:CodexConversationLayout-or$script:CodexConversationLayout.RowCount-ne3-or$script:CodexConversationLayout.ClientSize.Height-le0){throw 'Conversation three-row layout was not created.'}
            if($script:CodexConversationSplit.ClientSize.Width-lt860-and-not$script:CodexConversationSplit.Panel2Collapsed){throw 'Conversation file tree did not auto-collapse for a narrow window.'}
            if($script:CodexConversationHeader.Bottom-gt$script:CodexConversationOutputHost.Top-or$script:CodexConversationOutputHost.Bottom-gt$script:CodexConversationComposer.Top){throw 'Conversation message area overlaps the header or composer.'}
            if($script:CodexConversationOutput.ClientSize.Height-lt100-or$script:CodexConversationInput.ClientSize.Height-lt48){throw 'Conversation message or input area is vertically collapsed at the minimum window size.'}
            if(-not$script:CodexConversationOutput.AutoScroll-or$script:CodexConversationOutput.ConversationLayoutVersion-ne2){throw 'Conversation history does not expose the focus-stable buffered scroll container.'}
            $conversationHeaderButtons=@($script:CodexConversationPreviousUserButton,$script:CodexConversationStopButton,$script:CodexConversationReloadButton,$script:CodexConversationFileTreeToggleButton,$script:CodexConversationBackButton,$script:CodexConversationTerminalButton)
            if(@($conversationHeaderButtons|Where-Object{$null-eq$_}).Count-ne0-or$conversationHeaderButtons[0].Left-lt0){throw 'Conversation header buttons are missing or clipped at the minimum window size.'}
            for($headerButtonIndex=0;$headerButtonIndex-lt$conversationHeaderButtons.Count-1;$headerButtonIndex++){if($conversationHeaderButtons[$headerButtonIndex].Right+6-gt$conversationHeaderButtons[$headerButtonIndex+1].Left){throw ('Conversation header buttons overlap: '+$conversationHeaderButtons[$headerButtonIndex].Text+' / '+$conversationHeaderButtons[$headerButtonIndex+1].Text)}}
            if($null-eq$script:CodexConversationComposerResizeGrip-or$script:CodexConversationComposerResizeGrip.Cursor-ne[Windows.Forms.Cursors]::SizeNS-or$null-eq$script:CodexConversationComposerExpandButton){throw 'Conversation composer resize controls are missing.'}
            if($script:CodexConversationSend.Bounds.IntersectsWith($script:CodexConversationComposerExpandButton.Bounds)-or$script:CodexConversationAttachButton.Bounds.IntersectsWith($script:CodexConversationClearAttachmentsButton.Bounds)-or$script:CodexConversationComposerExpandButton.Right-gt$script:CodexConversationActions.ClientSize.Width-or$script:CodexConversationAttachButton.Right-gt$script:CodexConversationActions.ClientSize.Width-or$script:CodexConversationClearAttachmentsButton.Right-gt$script:CodexConversationActions.ClientSize.Width-or$script:CodexConversationAttachButton.Bottom-gt$script:CodexConversationActions.ClientSize.Height-or$script:CodexConversationClearAttachmentsButton.Bottom-gt$script:CodexConversationActions.ClientSize.Height){throw ('Conversation composer buttons overlap or exceed their action column: actions='+$script:CodexConversationActions.ClientSize+'; send='+$script:CodexConversationSend.Bounds+'; expand='+$script:CodexConversationComposerExpandButton.Bounds+'; attach='+$script:CodexConversationAttachButton.Bounds+'; clear='+$script:CodexConversationClearAttachmentsButton.Bounds+'.')}
            $composerLayoutWidth=[Math]::Max(1,$script:CodexConversationComposerLayout.ClientSize.Width)
            if($composerLayoutWidth-ge(ConvertTo-WorkflowDpiPixels 520 420)-and($script:CodexConversationActions.Width-gt[int][Math]::Ceiling($composerLayoutWidth*0.31)-or$script:CodexConversationInputFrame.Width-lt[int][Math]::Floor($composerLayoutWidth*0.64))){throw ('Conversation action column consumes too much horizontal space: layout='+$composerLayoutWidth+'; input='+$script:CodexConversationInputFrame.Width+'; actions='+$script:CodexConversationActions.Width+'.')}
            $composerInputWidthBeforeHeightChange=$script:CodexConversationInputFrame.Width;$composerActionsWidthBeforeHeightChange=$script:CodexConversationActions.Width
            $composerHeightBeforeExpand=[int][Math]::Round($script:CodexConversationComposerRowStyle.Height)
            $script:CodexConversationComposerExpandButton.PerformClick();[Windows.Forms.Application]::DoEvents()
            if(-not$script:CodexConversationComposerExpanded-or$script:CodexConversationComposerRowStyle.Height-le$composerHeightBeforeExpand-or$script:CodexConversationComposerExpandButton.Text-ne'还原'){throw 'Conversation composer expand action did not enlarge the input area.'}
            $script:CodexConversationComposerExpandButton.PerformClick();[Windows.Forms.Application]::DoEvents()
            if($script:CodexConversationComposerExpanded-or[Math]::Abs($script:CodexConversationComposerRowStyle.Height-$composerHeightBeforeExpand)-gt2-or$script:CodexConversationComposerExpandButton.Text-ne'展开'){throw 'Conversation composer restore action did not restore its previous height.'}
            [void](Set-CodexConversationComposerHeight ($composerHeightBeforeExpand+(ConvertTo-WorkflowDpiPixels 60 40)) -FromDrag);[Windows.Forms.Application]::DoEvents()
            if($script:CodexConversationComposerRowStyle.Height-le$composerHeightBeforeExpand-or$script:CodexConversationComposerExpanded){throw 'Conversation composer drag resizing did not enlarge the input area.'}
            if([Math]::Abs($script:CodexConversationInputFrame.Width-$composerInputWidthBeforeHeightChange)-gt3-or[Math]::Abs($script:CodexConversationActions.Width-$composerActionsWidthBeforeHeightChange)-gt3){throw 'Conversation vertical resizing unexpectedly changed the input/action column widths.'}
            $script:CodexConversationComposerUserHeight=0;Update-CodexConversationComposerHeight;[Windows.Forms.Application]::DoEvents()
            $longConversationText=(1..180|ForEach-Object{'长历史滚动测试行 '+$_.ToString('000')})-join"`r`n"
            Add-CodexConversationMessage 'assistant' $longConversationText
            [Windows.Forms.Application]::DoEvents()
            $lastBubble=$script:CodexConversationCurrentBubble
            $visualLineCount=[WorkflowNativeMethods]::GetRichTextLineCount($lastBubble.TextBox)
            if($lastBubble.TextBox.Height-le$script:CodexConversationOutput.ClientSize.Height-or-not$script:CodexConversationOutput.VerticalScroll.Visible-or$script:CodexConversationOutput.AutoScrollPosition.Y-ge0-or$visualLineCount-le10-or$lastBubble.TextBox.Height-lt(($visualLineCount*([Math]::Max(18,[int]$lastBubble.TextBox.Font.Height+3)))+10)){throw 'Conversation history did not wrap, size, or scroll through the final long bubble.'}
            if($lastBubble.TextBox.GetType().Name-ne'WorkflowConversationRichTextBox'-or$lastBubble.TextBox.ScrollPreservationVersion-ne2-or-not[object]::ReferenceEquals($lastBubble.TextBox.ScrollHost,$script:CodexConversationOutput)){throw 'Long conversation bubble does not use the current scroll-preserving text control.'}
            [void](Resize-CodexConversationBubbles -Force);[Windows.Forms.Application]::DoEvents()
            $stableBubbleHeights=@($script:CodexConversationBubbleRecords|ForEach-Object{[string]$_.Row.Height})-join',';$stableDisplayHeight=$script:CodexConversationOutput.DisplayRectangle.Height;$stableScrollMaximum=[Math]::Max(0,$stableDisplayHeight-$script:CodexConversationOutput.ClientSize.Height);$script:RepeatedConversationLayoutCount=0
            $repeatedLayoutHandler={param($sender,$eventArgs);$script:RepeatedConversationLayoutCount++};$script:CodexConversationOutput.Add_Layout($repeatedLayoutHandler)
            try{foreach($repeatResizeIndex in 1..160){[void](Resize-CodexConversationBubbles)}}finally{$script:CodexConversationOutput.Remove_Layout($repeatedLayoutHandler)}
            [Windows.Forms.Application]::DoEvents()
            if($script:RepeatedConversationLayoutCount-ne0-or(@($script:CodexConversationBubbleRecords|ForEach-Object{[string]$_.Row.Height})-join',')-ne$stableBubbleHeights-or$script:CodexConversationOutput.DisplayRectangle.Height-ne$stableDisplayHeight-or[Math]::Max(0,$script:CodexConversationOutput.DisplayRectangle.Height-$script:CodexConversationOutput.ClientSize.Height)-ne$stableScrollMaximum){throw 'Repeated same-size conversation layout changed bubble height or grew the lower blank area.'}
            foreach($forcedResizeIndex in 1..20){[void](Resize-CodexConversationBubbles -Force)};[Windows.Forms.Application]::DoEvents()
            if((@($script:CodexConversationBubbleRecords|ForEach-Object{[string]$_.Row.Height})-join',')-ne$stableBubbleHeights-or$script:CodexConversationOutput.DisplayRectangle.Height-ne$stableDisplayHeight){throw 'Repeated DPI-style forced measurement accumulated bubble or scroll height.'}
            $script:CodexConversationOutput.AutoScrollPosition=New-Object Drawing.Point(0,0);[Windows.Forms.Application]::DoEvents()
            $latestUserRecord.TextBox.Focus();[Windows.Forms.Application]::DoEvents()
            Scroll-CodexConversationToBottom;[Windows.Forms.Application]::DoEvents()
            $scrollBeforeCrossBubbleFocus=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y)
            $lastBubble.TextBox.Focus();[Windows.Forms.Application]::DoEvents();[Windows.Forms.Application]::DoEvents()
            $scrollAfterCrossBubbleFocus=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y)
            if([Math]::Abs($scrollAfterCrossBubbleFocus-$scrollBeforeCrossBubbleFocus)-gt2){throw 'Focusing a Codex bubble restored the stale position of a previously focused user bubble.'}
            $scrollBeforeFocus=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y)
            $lastBubble.TextBox.CaptureScrollHostPosition()
            $lastBubble.TextBox.Focus()
            $lastBubble.TextBox.SelectionStart=[Math]::Max(0,$lastBubble.TextBox.TextLength-4);$lastBubble.TextBox.SelectionLength=0
            [Windows.Forms.Application]::DoEvents();[Windows.Forms.Application]::DoEvents()
            $scrollAfterFocus=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y)
            if([Math]::Abs($scrollAfterFocus-$scrollBeforeFocus)-gt2){throw 'Focusing lower text in a long bubble changed the outer conversation scroll position.'}
            $scrollBeforeWheel=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y)
            if(-not(Scroll-CodexConversationFromMouseWheel 120 $lastBubble.TextBox.Font.Height)){throw 'Conversation bubble mouse-wheel forwarding was rejected.'}
            [Windows.Forms.Application]::DoEvents()
            $scrollAfterWheel=[Math]::Max(0,-$script:CodexConversationOutput.AutoScrollPosition.Y)
            if($scrollAfterWheel-ge$scrollBeforeWheel){throw 'Mouse wheel inside a conversation bubble did not scroll the outer conversation upward.'}
            Scroll-CodexConversationToBottom;[Windows.Forms.Application]::DoEvents()
            $bottomSpacer=$script:CodexConversationBottomSpacer
            if($null-eq$bottomSpacer-or$bottomSpacer.IsDisposed-or$bottomSpacer.Height-lt24-or$bottomSpacer.Top-lt$lastBubble.Row.Bottom){throw 'Conversation bottom spacer is missing or not placed after the final bubble.'}
            $viewportPoint=New-Object Drawing.Point;$viewportPoint.X=0;$viewportPoint.Y=[Math]::Max(0,$script:CodexConversationOutput.ClientSize.Height-1)
            $bubblePoint=New-Object Drawing.Point;$bubblePoint.X=0;$bubblePoint.Y=$lastBubble.Bubble.Height
            $viewportScreenPoint=$script:CodexConversationOutput.PointToScreen($viewportPoint);$viewportBottom=[int]$viewportScreenPoint.Y
            $bubbleScreenPoint=$lastBubble.Bubble.PointToScreen($bubblePoint);$bubbleBottom=[int]$bubbleScreenPoint.Y
            if(($viewportBottom-$bubbleBottom)-lt12){throw 'The final conversation bubble border cannot be fully scrolled into view.'}
            $script:MainForm.Size=$originalWindowSize
            [Windows.Forms.Application]::DoEvents()
            if($script:CodexConversationFileTreeUserVisible-and$script:CodexConversationSplit.ClientSize.Width-ge860-and$script:CodexConversationSplit.Panel2Collapsed){throw 'Conversation file tree did not restore after the window became wide again.'}
            Show-WorkflowAiConversation
            [Windows.Forms.Application]::DoEvents()
            if($script:CodexConversationMode-ne'WorkflowAi'-or-not$script:CodexConversationPanel.Visible-or$script:CodexConversationTerminalButton.Visible-or$script:CodexConversationTitle.Text-notlike'使驾 AI*'){throw '使驾 AI isolated conversation view did not open.'}
            if($script:CodexConversationFileTreeDirectory-ne(Resolve-ConfiguredPath $script:WorkflowAiDirectory)){throw '使驾 AI file tree did not switch to its isolated working directory.'}
            if($script:CodexConversationSend.Right -gt $script:CodexConversationSend.Parent.ClientSize.Width -or $script:CodexConversationInput.Right -gt $script:CodexConversationInput.Parent.ClientSize.Width){throw ('Conversation composer controls exceed the visible page width: send='+$script:CodexConversationSend.Right+'/'+$script:CodexConversationSend.Parent.ClientSize.Width+'; input='+$script:CodexConversationInput.Right+'/'+$script:CodexConversationInput.Parent.ClientSize.Width+'.')}
            Show-ProjectConversation
            if($script:CodexConversationMode-ne'Project'-or-not$script:CodexConversationTerminalButton.Visible-or$script:CodexConversationTitle.Text-notlike'Codex 会话*'){throw 'Project conversation did not restore after 使驾 AI.'}
            if($script:CodexConversationTerminalButton.Right -gt $script:CodexConversationTerminalButton.Parent.ClientSize.Width -or $script:CodexConversationReloadButton.Right -gt $script:CodexConversationReloadButton.Parent.ClientSize.Width){throw 'Conversation header controls exceed the visible page width.'}
            $script:SmokeStage='conversation-passive-observation'
            $passiveProcess=New-Object Diagnostics.Process
            $passiveProcess.StartInfo.FileName=$env:ComSpec
            $passiveProcess.StartInfo.Arguments='/d /c ping 127.0.0.1 -n 20 > nul'
            $passiveProcess.StartInfo.UseShellExecute=$false
            $passiveProcess.StartInfo.CreateNoWindow=$true
            [void]$passiveProcess.Start()
            $passiveKey=Get-CodexConversationProcessKey 'Project' ([string]$smokeProject.Id) 'smoke-session'
            $passiveRecord=[pscustomobject]@{Key=$passiveKey;Process=$passiveProcess;Mode='Project';ProjectId=[string]$smokeProject.Id;SessionId='smoke-session';InitialSessionId='smoke-session';WorkingDirectory=$testDirectory;OutputPath='';StopRequested=$false;TerminationReason='Running'}
            $script:CodexConversationProcesses[$passiveKey]=$passiveRecord
            try{
                Complete-ProjectCodexMessage;Complete-ProjectCodexMessage;Complete-ProjectCodexMessage
                if($passiveProcess.HasExited-or-not$script:CodexConversationProcesses.ContainsKey($passiveKey)-or[bool]$passiveRecord.StopRequested-or[string]$passiveRecord.TerminationReason-ne'Running'){throw 'Conversation polling terminated or mutated a running Codex process.'}
            }finally{
                $script:CodexConversationProcesses.Remove($passiveKey)
                try{if(-not$passiveProcess.HasExited){$passiveProcess.Kill()}}catch{}
                try{$passiveProcess.Dispose()}catch{}
            }
            $script:SmokeStage='conversation-nonblocking-output-drain'
            $drainProcess=New-Object Diagnostics.Process
            $drainProcess.StartInfo.FileName=$env:ComSpec
            $drainProcess.StartInfo.Arguments='/d /c exit 0'
            $drainProcess.StartInfo.UseShellExecute=$false
            $drainProcess.StartInfo.CreateNoWindow=$true
            [void]$drainProcess.Start()
            if(-not$drainProcess.WaitForExit(5000)){throw 'Conversation drain test process did not exit.'}
            $drainStdOut=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
            $drainStdErr=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
            $drainKey=Get-CodexConversationProcessKey 'Project' ([string]$smokeProject.Id) 'smoke-session'
            $drainRecord=[pscustomobject]@{Key=$drainKey;Process=$drainProcess;StdOut=$drainStdOut.Task;StdErr=$drainStdErr.Task;Mode='Project';ProjectId=[string]$smokeProject.Id;SessionId='smoke-session';InitialSessionId='smoke-session';WorkingDirectory=$testDirectory;OutputPath='';StopRequested=$false;TerminationReason='Running';FinalizeState='Running';ExitObservedAt=$null;OutputDrainDeadline=$null}
            $script:CodexConversationProcesses[$drainKey]=$drainRecord
            try{
                $drainWatch=[Diagnostics.Stopwatch]::StartNew();Complete-ProjectCodexMessage;$drainWatch.Stop()
                if($drainWatch.ElapsedMilliseconds-ge500){throw ('Conversation output drain blocked the UI thread for '+$drainWatch.ElapsedMilliseconds+' ms.')}
                if(-not$script:CodexConversationProcesses.ContainsKey($drainKey)-or[string]$drainRecord.FinalizeState-ne'DrainingOutput'-or-not(Test-CodexConversationProcessBusy $drainKey)-or(Test-CodexConversationProcessRunning $drainKey)){throw 'Exited conversation did not enter the non-blocking output drain state.'}
                if($script:CodexConversationSend.Enabled-or$script:CodexConversationStopButton.Enabled-or$script:CodexConversationStatus.Text-notlike'*正在同步回复*'){throw 'Conversation controls are invalid while exited output is draining.'}
                $drainStdOut.SetResult('');$drainStdErr.SetResult('');Complete-ProjectCodexMessage
                if($script:CodexConversationProcesses.ContainsKey($drainKey)-or-not$script:CodexConversationSend.Enabled){throw 'Conversation did not finalize after redirected output completed.'}
                Complete-ProjectCodexMessage
            }finally{
                if($script:CodexConversationProcesses.ContainsKey($drainKey)){$script:CodexConversationProcesses.Remove($drainKey)}
                try{$drainProcess.Dispose()}catch{}
                Update-CodexConversationControls
            }
            $script:SmokeStage='conversation-output-file-completion'
            $outputReadyProcess=New-Object Diagnostics.Process
            $outputReadyProcess.StartInfo.FileName=$env:ComSpec
            $outputReadyProcess.StartInfo.Arguments='/d /c ping 127.0.0.1 -n 20'
            $outputReadyProcess.StartInfo.UseShellExecute=$false
            $outputReadyProcess.StartInfo.CreateNoWindow=$true
            [void]$outputReadyProcess.Start()
            $outputReadyPath=Join-Path $testDirectory 'codex-output-ready.txt'
            [IO.File]::WriteAllText($outputReadyPath,'completed reply',[Text.Encoding]::UTF8)
            $outputReadyStdOut=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]';$outputReadyStdOut.SetResult('')
            $outputReadyStdErr=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]';$outputReadyStdErr.SetResult('')
            $outputReadyKey=Get-CodexConversationProcessKey 'Project' ([string]$smokeProject.Id) 'output-ready-session'
            $outputReadyRecord=[pscustomobject]@{Key=$outputReadyKey;Process=$outputReadyProcess;StdOut=$outputReadyStdOut.Task;StdErr=$outputReadyStdErr.Task;Mode='Project';ProjectId=[string]$smokeProject.Id;SessionId='output-ready-session';InitialSessionId='output-ready-session';WorkingDirectory=$testDirectory;OutputPath=$outputReadyPath;StartedAt=(Get-Date).AddSeconds(-1);StopRequested=$false;TerminationReason='Running';FinalizeState='Running';ExitObservedAt=$null;OutputDrainDeadline=$null}
            $script:CodexConversationProcesses[$outputReadyKey]=$outputReadyRecord
            try{
                if(Test-CodexConversationProcessRunning $outputReadyKey){throw 'A Codex process with a completed output file was still reported as running.'}
                Complete-ProjectCodexMessage
                if($script:CodexConversationProcesses.ContainsKey($outputReadyKey)){throw 'Completed Codex output did not clean up the stale host process record.'}
            }finally{
                if($script:CodexConversationProcesses.ContainsKey($outputReadyKey)){$script:CodexConversationProcesses.Remove($outputReadyKey)}
                try{if(-not$outputReadyProcess.HasExited){$outputReadyProcess.Kill()}}catch{}
                try{$outputReadyProcess.Dispose()}catch{}
                Remove-Item -LiteralPath $outputReadyPath -Force -ErrorAction SilentlyContinue
            }
            $script:SmokeStage='conversation-output-drain-timeout'
            $timeoutProcess=New-Object Diagnostics.Process
            $timeoutProcess.StartInfo.FileName=$env:ComSpec
            $timeoutProcess.StartInfo.Arguments='/d /c exit 0'
            $timeoutProcess.StartInfo.UseShellExecute=$false
            $timeoutProcess.StartInfo.CreateNoWindow=$true
            [void]$timeoutProcess.Start()
            if(-not$timeoutProcess.WaitForExit(5000)){throw 'Conversation timeout test process did not exit.'}
            $timeoutStdOut=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
            $timeoutStdErr=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
            $timeoutKey=Get-CodexConversationProcessKey 'Project' ([string]$smokeProject.Id) 'smoke-session'
            $timeoutRecord=[pscustomobject]@{Key=$timeoutKey;Process=$timeoutProcess;StdOut=$timeoutStdOut.Task;StdErr=$timeoutStdErr.Task;Mode='Project';ProjectId=[string]$smokeProject.Id;SessionId='smoke-session';InitialSessionId='smoke-session';WorkingDirectory=$testDirectory;OutputPath='';StopRequested=$false;TerminationReason='Running';FinalizeState='DrainingOutput';ExitObservedAt=(Get-Date).AddSeconds(-10);OutputDrainDeadline=(Get-Date).AddSeconds(-1)}
            $script:CodexConversationProcesses[$timeoutKey]=$timeoutRecord
            try{
                $timeoutWatch=[Diagnostics.Stopwatch]::StartNew();Complete-ProjectCodexMessage;$timeoutWatch.Stop()
                if($timeoutWatch.ElapsedMilliseconds-ge1500-or$script:CodexConversationProcesses.ContainsKey($timeoutKey)-or[string]$timeoutRecord.FinalizeState-ne'Finalized'){throw 'Timed-out conversation output did not force a bounded finalization.'}
            }finally{
                if($script:CodexConversationProcesses.ContainsKey($timeoutKey)){$script:CodexConversationProcesses.Remove($timeoutKey)}
                try{$timeoutProcess.Dispose()}catch{}
                Update-CodexConversationControls
            }
            $script:SmokeStage='conversation-manual-stop'
            $manualStopProcess=New-Object Diagnostics.Process
            $manualStopProcess.StartInfo.FileName=$env:ComSpec
            $manualStopProcess.StartInfo.Arguments='/d /c ping 127.0.0.1 -n 20'
            $manualStopProcess.StartInfo.UseShellExecute=$false
            $manualStopProcess.StartInfo.CreateNoWindow=$true
            $manualStopProcess.StartInfo.RedirectStandardOutput=$true
            $manualStopProcess.StartInfo.RedirectStandardError=$true
            [void]$manualStopProcess.Start()
            $manualStopKey=Get-CodexConversationProcessKey 'Project' ([string]$smokeProject.Id) 'smoke-session'
            $manualStopRecord=[pscustomobject]@{Key=$manualStopKey;Process=$manualStopProcess;StdOut=$manualStopProcess.StandardOutput.ReadToEndAsync();StdErr=$manualStopProcess.StandardError.ReadToEndAsync();Mode='Project';ProjectId=[string]$smokeProject.Id;SessionId='smoke-session';InitialSessionId='smoke-session';OutputPath='';StopRequested=$false}
            $script:CodexConversationProcesses[$manualStopKey]=$manualStopRecord
            try{
                Update-CodexConversationControls
                if($null-eq$script:CodexConversationStopButton-or-not$script:CodexConversationStopButton.Enabled){throw 'Conversation stop button was not enabled for a running message.'}
                if(-not(Stop-CurrentCodexConversation)){throw 'Conversation manual stop request was rejected.'}
                if(-not$manualStopProcess.WaitForExit(5000)){throw 'Conversation process did not stop within the timeout.'}
                Complete-ProjectCodexMessage
                if($script:CodexConversationProcesses.ContainsKey($manualStopKey)-or$script:CodexConversationStopButton.Enabled-or$script:CodexConversationStatus.Text-notlike'*手动停止*'){throw 'Conversation manual stop did not clean up process state or expose stopped status.'}
            }finally{
                if($script:CodexConversationProcesses.ContainsKey($manualStopKey)){$script:CodexConversationProcesses.Remove($manualStopKey)}
                try{if(-not$manualStopProcess.HasExited){$manualStopProcess.Kill()}}catch{}
                try{$manualStopProcess.Dispose()}catch{}
                Update-CodexConversationControls
            }
            $script:SmokeStage='empty-project-conversation'
            $emptyProjectSelectorIndex=-1;for($projectIndex=0;$projectIndex-lt$script:ProjectSelector.Items.Count;$projectIndex++){if([string]$script:ProjectSelector.Items[$projectIndex].Id-eq[string]$emptySessionProject.Id){$emptyProjectSelectorIndex=$projectIndex;break}}
            if($emptyProjectSelectorIndex-lt0){throw 'Session-less project is missing from the selector.'}
            $script:ProjectSelector.SelectedIndex=$emptyProjectSelectorIndex;[Windows.Forms.Application]::DoEvents()
            if(-not$script:ProjectChatButton.Enabled-or$script:ProjectTerminalButton.Enabled){throw 'Session-less project conversation/terminal action state is invalid.'}
            Show-ProjectConversation;[Windows.Forms.Application]::DoEvents()
            if(-not$script:CodexConversationPanel.Visible-or$script:CodexConversationOutput.Text-notlike'*发送第一条消息后*'-or$script:CodexConversationStatus.Text-notlike'*自动创建并绑定会话*'){throw 'Session-less project did not open an empty first-message conversation.'}
            $script:ProjectSelector.SelectedIndex=$smokeProjectSelectorIndex;[Windows.Forms.Application]::DoEvents();Show-ProjectConversation
            $busyRecord=[pscustomobject]@{WorkflowId='codex-lock-smoke';WorkflowName='占用会话任务';ActiveCodexSessionId='smoke-session'}
            $script:RunningJobs[[string]$busyRecord.WorkflowId]=$busyRecord
            try{Update-CodexConversationControls;if($script:CodexConversationSend.Enabled-or$script:CodexConversationInput.Enabled-or$script:CodexConversationStatus.Text-notlike'*占用会话任务*'){throw 'Workflow Codex session lock did not disable project conversation sending.'}}
            finally{$script:RunningJobs.Remove([string]$busyRecord.WorkflowId);Update-CodexConversationControls}
            if(-not$script:CodexConversationSend.Enabled-or-not$script:CodexConversationInput.Enabled){throw 'Project conversation controls did not unlock after Codex node completion.'}
            $script:SmokeStage='common-prompts-page'
            if($null-eq$script:CommonPromptsButton-or$script:CommonPromptsButton.Text-ne'常用提示词'-or$script:CommonPromptsButton.Left-le$script:RunningTasksButton.Left){throw 'Common prompt header entry is missing or not placed to the right of running tasks.'}
            $script:CommonPromptsButton.PerformClick()
            [Windows.Forms.Application]::DoEvents()
             if($null-eq$script:CommonPromptsForm-or$script:CommonPromptsForm.IsDisposed-or-not$script:CommonPromptsForm.Visible-or$script:CommonPromptsForm.Modal-or$script:CommonPromptsPanel.Parent-ne$script:CommonPromptsForm-or-not$script:CommonPromptsPanel.Visible-or-not$script:CodexConversationPanel.Visible){throw 'Common prompt floating window is not modeless or obscured the conversation.'}
             if($null-eq$script:CommonPromptList-or$script:CommonPromptList.Items.Count-ne2-or[string]$script:CommonPromptList.Items[0]-ne'检查当前修改并给出风险'){throw 'Common prompt page did not clean legacy False values or load normal prompts.'}
             if($script:CommonPromptList.DrawMode-ne[Windows.Forms.DrawMode]::OwnerDrawVariable-or$script:CommonPromptList.IntegralHeight){throw 'Common prompt list styling is invalid.'}
            if(-not$script:CommonPromptEditButton.Enabled-or-not$script:CommonPromptDeleteButton.Enabled-or-not$script:CommonPromptCopyButton.Enabled){throw 'Common prompt actions were not enabled for the selected prompt.'}
            if((ConvertTo-CommonPromptValue @([bool]$false,'False','合法提示词'))-ne'合法提示词'){throw 'Common prompt output normalization did not reject Boolean or False text pollution.'}
            Save-GlobalSettings
            $loadedPromptSettings=Load-GlobalSettings
            if(@($loadedPromptSettings.CommonPrompts).Count-ne2-or[string]$loadedPromptSettings.CommonPrompts[1]-ne'整理执行日志并给出下一步'){throw 'Common prompts were not persisted in global settings.'}
            $script:CommonPromptBackButton.PerformClick()
             [Windows.Forms.Application]::DoEvents()
             if($null-ne$script:CommonPromptsForm-and-not$script:CommonPromptsForm.IsDisposed-or$script:CommonPromptsPanel.Visible-or-not$script:CodexConversationPanel.Visible){throw 'Closing the common prompt floating window did not restore the conversation page.'}
            $script:SmokeStage='running-task-page'
            $smokeRunningProcess=[Diagnostics.Process]::GetCurrentProcess()
            $smokeRunningRecord=[pscustomobject]@{Worker=[pscustomobject]@{Process=$smokeRunningProcess};WorkflowId='smoke-running-task';WorkflowName='实时日志测试任务';Manual=$true;DoneEvent=$false;StartedAt=(Get-Date).AddSeconds(-3);Status='运行中';CurrentNodeId='smoke-cmd';CurrentNodeName='实时 CMD';CurrentNodeType='Cmd';ActiveProcessId=43210;NodeStack=(New-Object Collections.ArrayList);Logs=(New-Object Collections.ArrayList);StopRequested=$false}
            Add-RunningTaskLog $smokeRunningRecord '任务已启动。' 'INFO' 'Lifecycle'
            Add-RunningTaskLog $smokeRunningRecord '[stdout] first-line' 'INFO' 'CommandOutput'
            $script:RunningJobs[[string]$smokeRunningRecord.WorkflowId]=$smokeRunningRecord
            try{
                Show-RunningTasksPage
                [Windows.Forms.Application]::DoEvents()
                if(-not$script:RunningTasksPanel.Visible-or$script:CommonPromptsPanel.Visible-or$script:Canvas.Visible-or$script:WorkflowSettingsPanel.Visible-or$script:CodexConversationPanel.Visible){throw 'Running task page visibility is invalid.'}
                if($null-eq$script:RunningTasksButton-or$script:RunningTasksButton.Text-ne'运行中任务 (1)'-or$script:RunningTasksGrid.Columns.Count-ne5-or$script:RunningTasksGrid.Rows.Count-ne1){throw 'Running task entry, counter, or grid columns are invalid.'}
                if($script:RunningTaskTitle.Text-ne'实时日志测试任务'-or$script:RunningTaskMeta.Text.IndexOf('实时 CMD [Cmd]',[StringComparison]::Ordinal)-lt0-or$script:RunningTaskMeta.Text.IndexOf('43210',[StringComparison]::Ordinal)-lt0){throw 'Running task node and process metadata are invalid.'}
                if($script:RunningTaskLogBox.Text-notlike'*first-line*'-or-not$script:RunningTaskStopButton.Enabled){throw 'Running task live log or stop action is unavailable.'}
                Add-RunningTaskLog $smokeRunningRecord '[stderr] second-line' 'ERROR' 'CommandOutput'
                Refresh-RunningTasksView
                if($script:RunningTaskLogBox.Text-notlike'*second-line*'){throw 'Running task log view did not append new output.'}
                $script:RunningTaskLogBox.SelectionStart=0;$script:RunningTaskLogBox.SelectionLength=0
                $selectionBeforeIdleRefresh=$script:RunningTaskLogBox.SelectionStart
                $selectedTaskBeforeIdleRefresh=Get-SelectedRunningTaskId
                Refresh-RunningTasksView
                if($script:RunningTaskLogBox.SelectionStart-ne$selectionBeforeIdleRefresh){throw 'Running task log moved the caret even though no new log was appended.'}
                if((Get-SelectedRunningTaskId)-ne$selectedTaskBeforeIdleRefresh){throw 'Running task list changed selection during an idle refresh.'}
                if($script:RunningTaskBackButton.Right-gt$script:RunningTaskBackButton.Parent.ClientSize.Width-or$script:RunningTaskStopButton.Right-gt$script:RunningTaskStopButton.Parent.ClientSize.Width){throw 'Running task page actions exceed the visible page width.'}
            }finally{
                $script:RunningJobs.Remove([string]$smokeRunningRecord.WorkflowId)
                Refresh-RunningTasksView
            }
            Show-WorkflowWorkspace
            if($script:RunningTasksPanel.Visible-or-not$script:Canvas.Visible-or-not$script:WorkflowSettingsPanel.Visible){throw 'Returning from the running task page did not restore the workflow workspace.'}
            $script:SmokeStage='workflow-click-returns-from-conversation'
            $sameWorkflowIndex=$script:WorkflowList.SelectedIndex
            $workflowMouseDown=$script:WorkflowList.GetType().GetMethod('OnMouseDown',[Reflection.BindingFlags]'Instance,NonPublic')
            $itemY=[Math]::Max(2,($sameWorkflowIndex*$script:WorkflowList.ItemHeight)+[Math]::Floor($script:WorkflowList.ItemHeight/2))
            $workflowMouseDown.Invoke($script:WorkflowList,[object[]]@([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left,1,12,$itemY,0)))|Out-Null
            if ($script:CodexConversationPanel.Visible -or -not $script:Canvas.Visible -or -not $script:WorkflowSettingsPanel.Visible) { throw 'Clicking the selected workflow did not restore its workspace.' }
            if($null-eq$script:WorkflowListContextMenu-or@($script:WorkflowListContextMenu.Items|Where-Object{$_.Text-eq'复制工作任务'}).Count-ne1-or@($script:WorkflowListContextMenu.Items|Where-Object{$_.Text-eq'粘贴到当前项目'}).Count-ne1-or@($script:WorkflowListContextMenu.Items|Where-Object{$_.Text-eq'上移'}).Count-ne1-or@($script:WorkflowListContextMenu.Items|Where-Object{$_.Text-eq'下移'}).Count-ne1-or@($script:WorkflowListContextMenu.Items|Where-Object{$_.Text-eq'停止'}).Count-ne1-or@($script:WorkflowListContextMenu.Items|Where-Object{$_.Text-eq'重新执行'}).Count-ne1){throw 'Workflow list move/copy/paste/stop/restart/delete context menu is missing.'}
            $moveSource=$script:WorkflowList.Items[1];$script:WorkflowList.SelectedIndex=1
            if(-not(Move-SelectedWorkflow -Direction -1)){throw 'Workflow list move-up action failed.'}
            if([string]$script:WorkflowList.Items[0].Id-ne[string]$moveSource.Id-or(Get-WorkflowMoveState $moveSource).CanMoveUp){throw 'Workflow list move-up order or boundary state is invalid.'}
            $script:SmokeStage='workflow-copy-paste'
            $sourceWorkflow=$script:CurrentWorkflow
            $sourceWorkflow.Enabled=$true
            if(-not(Copy-SelectedWorkflow)){throw 'Workflow copy failed.'}
            $pastedWorkflow=Paste-CopiedWorkflow
            if($null-eq$pastedWorkflow-or[string]$pastedWorkflow.Id-eq[string]$sourceWorkflow.Id-or[string]$pastedWorkflow.ProjectId-ne[string]$smokeProject.Id-or$pastedWorkflow.Enabled){throw 'Pasted workflow identity, project, or enabled state is invalid.'}
            if(@($pastedWorkflow.Nodes).Count-ne@($sourceWorkflow.Nodes).Count-or@($pastedWorkflow.Edges).Count-ne@($sourceWorkflow.Edges).Count){throw 'Pasted workflow did not preserve graph structure.'}
            $sourceNodeIds=@($sourceWorkflow.Nodes|ForEach-Object{[string]$_.Id});if(@($pastedWorkflow.Nodes|Where-Object{$sourceNodeIds-contains[string]$_.Id}).Count-ne0){throw 'Pasted workflow reused source node IDs.'}
            $pastedNodeIds=@($pastedWorkflow.Nodes|ForEach-Object{[string]$_.Id});if(@($pastedWorkflow.Edges|Where-Object{$pastedNodeIds-notcontains[string]$_.From-or$pastedNodeIds-notcontains[string]$_.To}).Count-ne0){throw 'Pasted workflow edges do not reference cloned node IDs.'}
            if ($null -eq $script:Canvas -or $script:Canvas.Width -le 100) { throw 'Canvas was not created.' }
            $screenBounds = [Windows.Forms.Screen]::FromControl($script:MainForm).Bounds
            if ($script:Canvas.AutoScrollMinSize.Width -lt ($screenBounds.Width * 2) -or $script:Canvas.AutoScrollMinSize.Height -lt ($screenBounds.Height * 2)) { throw 'Canvas extent is smaller than twice the current screen size.' }
            $script:SmokeStage = 'far-grid-render'
            $script:Canvas.AutoScrollPosition = New-Object Drawing.Point([Math]::Max(0,$script:Canvas.AutoScrollMinSize.Width-$script:Canvas.ClientSize.Width),[Math]::Max(0,$script:Canvas.AutoScrollMinSize.Height-$script:Canvas.ClientSize.Height))
            $script:Canvas.Refresh()
            if ($null -ne $script:CanvasRenderError) { throw ('Far canvas grid repaint failed: ' + $script:CanvasRenderError) }
            $script:Canvas.AutoScrollPosition = New-Object Drawing.Point(0,0)
            if (@($script:CurrentWorkflow.Nodes).Count -lt 2) { throw 'Workflow nodes were not bound.' }
            $toolbarButtons = @($script:CommandPanel.Controls | Where-Object { $_ -is [Windows.Forms.Button] })
            $toolbarTexts = @($toolbarButtons | ForEach-Object { $_.Text })
            if($null-eq$script:WorkflowHeaderBrand-or$script:WorkflowHeaderBrand.Text-ne'使驾   --让您高速驾驶'){throw 'Compact header brand text is invalid.'}
            if($script:CommandPanel.Parent-ne$script:WorkflowSettingsPanel){throw 'Workflow node toolbar is not inside the workflow page.'}
            foreach ($removedText in @('+ 工作流','树状排布','Codex 示例')) { if ($toolbarTexts -contains $removedText) { throw "Removed toolbar button still exists: $removedText" } }
            $cmdButton = @($toolbarButtons | Where-Object Text -eq '+ CMD' | Select-Object -First 1)
            if ($cmdButton.Count -ne 1 -or $cmdButton[0].FlatStyle -ne [Windows.Forms.FlatStyle]::Flat) { throw 'Styled CMD toolbar button was not created.' }
            foreach ($requiredButton in @('+ 赋值','+ CMD','+ Python','+ 调用 Codex','+ 判断','+ 循环','+ 循环结束','+ 延时')) { if ($toolbarTexts -notcontains $requiredButton) { throw "Missing workflow toolbar button: $requiredButton" } }
            $actionTexts=@($script:WorkflowActionsPanel.Controls|Where-Object{$_-is[Windows.Forms.Button]}|ForEach-Object{$_.Text})
            foreach($requiredAction in @('保存','立即运行','删除选中')){if($actionTexts-notcontains$requiredAction){throw "Missing workflow page action: $requiredAction"}}
            if($null-eq$script:ScheduleButton-or$script:ScheduleButton.Text-ne'定时配置'){throw 'Workflow schedule dialog entry is missing.'}
            $workflowMenuTexts=@($script:WorkflowListContextMenu.Items|ForEach-Object{$_.Text})
            if($workflowMenuTexts-notcontains'执行一次'){throw 'Workflow context menu run-once entry is missing.'}
            $trayMenuTexts=@($script:TrayMenu.Items|ForEach-Object{$_.Text})
            foreach($removedTrayText in @('运行当前任务','运行全部启用任务')){if($trayMenuTexts-contains$removedTrayText){throw "Removed tray action still exists: $removedTrayText"}}
            if($null -eq $script:CanvasContextMenu -or @($script:CanvasContextMenu.Items|Where-Object { $_.Text -eq '复制节点' }).Count -ne 1 -or @($script:CanvasContextMenu.Items|Where-Object { $_.Text -eq '粘贴节点' }).Count -ne 1){throw 'Canvas copy/paste context menu is missing.'}
            $script:SmokeStage='project-editor-session-picker';Invoke-ProjectEditorSmokeTest $script:CodexSessionCache[0]
            $script:SmokeStage='schedule-dialog';Invoke-ScheduleEditorSmokeTest
            if ($null -eq $script:ScheduleModeBox -or $script:ScheduleModeBox.IsDisposed -or $script:ScheduleModeBox.Items.Count -ne 2 -or $null -eq $script:ScheduleKindBox -or $script:ScheduleKindBox.Items.Count -ne 4 -or $null -eq $script:IntervalBox -or $script:IntervalBox.IsDisposed) { throw 'Schedule editor controls were not initialized.' }
            $legacyWriteRows = @(Get-UiEnvironmentItems ([pscustomobject]@{ Items = [pscustomobject]@{ A = '1'; B = '2' } }))
            if ($legacyWriteRows.Count -ne 2 -or @($legacyWriteRows | Where-Object { $null -eq $_.PSObject.Properties['Name'] }).Count -ne 0) { throw 'Legacy variable object normalization failed.' }
            $missingNameRows = @(Get-UiEnvironmentItems ([pscustomobject]@{ Items = @([pscustomobject]@{ Value = 'orphan' }) }))
            if ($missingNameRows.Count -ne 1 -or $null -eq $missingNameRows[0].PSObject.Properties['Name']) { throw 'Missing variable name normalization failed.' }
            $cmdEditorNode=New-WorkflowNode 'Cmd' 'CMD editor test' 0 0 ([pscustomobject]@{ Command = 'echo ok'; WorkingDirectory = ''; TimeoutSeconds = ''; OutputVar = 'cmdResult'; FailOnError = $true })
            $script:SmokeStage = 'cmd-editor'; Invoke-NodeEditorSmokeTest $cmdEditorNode -Save
            if([string]$cmdEditorNode.Config.TimeoutSeconds-ne''){throw 'CMD editor did not preserve the no-timeout mode.'}
            $pythonEditorNode=New-WorkflowNode 'Python' 'Python editor test' 0 0 ([pscustomobject]@{ Mode='Inline'; Script='print("ok")'; WorkingDirectory=''; Arguments=''; TimeoutSeconds=''; OutputVar='pythonResult'; FailOnError=$true })
            $script:SmokeStage='python-editor';Invoke-NodeEditorSmokeTest $pythonEditorNode -Save
            if([string]$pythonEditorNode.Config.Mode-ne'Inline'-or[string]$pythonEditorNode.Config.Script-ne'print("ok")'-or[string]$pythonEditorNode.Config.TimeoutSeconds-ne''-or[string]$pythonEditorNode.Config.OutputVar-ne'pythonResult'){throw 'Python editor did not preserve its mode, script, optional timeout, or output variable.'}
            $codexEditorNode = New-WorkflowNode 'Codex' 'Codex editor test' 0 0 ([pscustomobject]@{ WorkingDirectory = ''; SessionId = '{{var.sessionId}}'; Request = 'Summarize {{var.input}}'; LiveData = '{{var.input}}'; TimeoutSeconds = 600; OutputVar = 'codexResult'; FailOnError = $true })
            $script:SmokeStage = 'codex-editor'; Invoke-NodeEditorSmokeTest $codexEditorNode -Save
            if ($null -ne $codexEditorNode.Config.PSObject.Properties['CodexPath'] -or $codexEditorNode.Config.WorkingDirectory -ne '' -or $codexEditorNode.Config.SessionId -ne '{{var.sessionId}}' -or $codexEditorNode.Config.OutputVar -ne 'codexResult') { throw 'Codex editor did not preserve its project-aware configuration.' }
            $script:SmokeStage = 'env-read-editor'; Invoke-NodeEditorSmokeTest (New-WorkflowNode 'EnvRead' 'Env read editor test' 0 0 ([pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'A'; Variable = 'a' }) })) -Save
            $script:SmokeStage = 'env-write-editor'; Invoke-NodeEditorSmokeTest (New-WorkflowNode 'EnvWrite' 'Env write editor test' 0 0 ([pscustomobject]@{ Items = @([pscustomobject]@{ Name = 'A'; Value = '1' }) })) -Save
            $script:SmokeStage = 'variable-editor'; Invoke-NodeEditorSmokeTest (New-WorkflowNode 'Variable' 'Variable editor test' 0 0 ([pscustomobject]@{ Name = 'value'; ValueType = 'String'; Value = 'ok' })) -Save
            $script:SmokeStage = 'if-editor'; Invoke-NodeEditorSmokeTest (New-WorkflowNode 'If' 'If editor test' 0 0 ([pscustomobject]@{ Left = '1'; Operator = 'Equals'; Right = '1'; OutputVar = 'condition' })) -Save
            $script:SmokeStage = 'foreach-editor'; Invoke-NodeEditorSmokeTest (New-WorkflowNode 'ForEach' 'ForEach editor test' 0 0 ([pscustomobject]@{ Items = '[1]'; ItemVariable = 'item'; IndexVariable = 'index'; ResultVariable = 'loop' })) -Save
            $script:SmokeStage = 'loop-end-editor'; Invoke-NodeEditorSmokeTest (New-WorkflowNode 'LoopEnd' 'Loop end editor test' 0 0 ([pscustomobject]@{})) -Save
            $script:SmokeStage = 'delay-editor'; Invoke-NodeEditorSmokeTest (New-WorkflowNode 'Delay' 'Delay editor test' 0 0 ([pscustomobject]@{ Seconds = 0.5 })) -Save
            $balloonEditorNode=New-WorkflowNode 'Balloon' 'Balloon editor test' 0 0 ([pscustomobject]@{Title='可点击提醒';Message='完成';ClickAction='OpenUrl';ClickTarget='https://example.com/{{var.id}}'})
            $script:SmokeStage='balloon-editor';Invoke-NodeEditorSmokeTest $balloonEditorNode -Save
            if([string]$balloonEditorNode.Config.ClickAction-ne'OpenUrl'-or[string]$balloonEditorNode.Config.ClickTarget-ne'https://example.com/{{var.id}}'){throw 'Balloon editor did not preserve click behavior and target.'}
            $script:SmokeStage = 'standard-minimize'
            $script:MainForm.WindowState = [Windows.Forms.FormWindowState]::Minimized
            [Windows.Forms.Application]::DoEvents()
            if (-not $script:MainForm.Visible -or -not $script:MainForm.ShowInTaskbar) { throw 'Minimize should keep the window visible in the taskbar.' }
            $script:MainForm.WindowState = [Windows.Forms.FormWindowState]::Normal
            Set-WorkflowWindowIcon $script:MainForm
            if ([WorkflowNativeMethods]::GetWindowIcon($script:MainForm, $false) -eq [IntPtr]::Zero -or [WorkflowNativeMethods]::GetWindowIcon($script:MainForm, $true) -eq [IntPtr]::Zero) { throw 'Native title-bar icon handles are missing.' }
            $stableWindowHandle = $script:MainForm.Handle
            $script:SmokeStage = 'tray-hide'; Hide-WorkflowManagerToTray
            if (-not $script:NotifyIcon.Visible -or $script:MainForm.Visible -or -not $script:MainForm.ShowInTaskbar -or $script:MainForm.Handle -ne $stableWindowHandle) { throw 'Tray hide state or stable window handle is invalid.' }
            if (-not $script:MainForm.ShowIcon -or $null -eq $script:MainForm.Icon -or $null -eq $script:NotifyIcon.Icon) { throw 'Window or tray icon is missing.' }
            $script:SmokeStage = 'tray-single-click'
            $notifyMouseClick = $script:NotifyIcon.GetType().GetMethod('OnMouseClick', [Reflection.BindingFlags]'Instance,NonPublic')
            if ($null -eq $notifyMouseClick) { throw 'NotifyIcon single-click method is unavailable.' }
            $notifyMouseClick.Invoke($script:NotifyIcon, [object[]]@([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, 0, 0, 0))) | Out-Null
            if (-not $script:NotifyIcon.Visible -or -not $script:MainForm.Visible -or -not $script:MainForm.ShowInTaskbar -or $script:MainForm.Handle -ne $stableWindowHandle) { throw 'Tray restore state or stable window handle is invalid.' }
            $closeArgs = [Windows.Forms.FormClosingEventArgs]::new([Windows.Forms.CloseReason]::UserClosing, $false)
            $closeMethod = $script:MainForm.GetType().GetMethod('OnFormClosing', [Reflection.BindingFlags]'Instance,NonPublic')
            $script:SmokeStage = 'form-closing'; $closeMethod.Invoke($script:MainForm, [object[]]@($closeArgs)) | Out-Null
            if (-not $closeArgs.Cancel -or $script:MainForm.Visible -or $script:MainForm.Handle -ne $stableWindowHandle) { throw 'Window close was not smoothly redirected to tray.' }
            $script:SmokeStage = 'edge-select'; Restore-WorkflowManagerFromTray
            $edgeClickArgs = [object[]]@([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, 310, 146, 0))
            $mouseDown = $script:Canvas.GetType().GetMethod('OnMouseDown', [Reflection.BindingFlags]'Instance,NonPublic')
            $directEdgeProbe = Get-EdgeAt 310 146
            if ($null -eq $directEdgeProbe) { throw 'Direct Get-EdgeAt probe failed at 310,146.' }
            $mouseDown.Invoke($script:Canvas, $edgeClickArgs) | Out-Null
            if ($null -eq $script:SelectedEdge) {
                $edgeSummary = @($script:CurrentWorkflow.Edges | ForEach-Object { "$($_.From)->$($_.To)" }) -join ','
                $nodeSummary = @($script:CurrentWorkflow.Nodes | ForEach-Object { "$($_.Type):$($_.X),$($_.Y),$($_.Width),$($_.Height)" }) -join ';'
                throw "Canvas edge selection failed at 310,146; edges=$edgeSummary; nodes=$nodeSummary"
            }
            $script:Canvas.Refresh()
            if ($null -ne $script:CanvasRenderError) { throw ('Selected edge repaint failed: ' + $script:CanvasRenderError) }
            if (-not $script:Canvas.Focused) { throw 'Canvas did not receive focus after mouse selection.' }
            $script:SmokeStage = 'edge-delete-key'; $deleteArgs = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Delete)
            $formKeyDown = $script:MainForm.GetType().GetMethod('OnKeyDown', [Reflection.BindingFlags]'Instance,NonPublic')
            $formKeyDown.Invoke($script:MainForm, [object[]]@($deleteArgs)) | Out-Null
            if (-not $deleteArgs.Handled -or -not $deleteArgs.SuppressKeyPress) { throw 'Delete shortcut was not handled by the main window.' }
            if (@($script:CurrentWorkflow.Edges).Count -ne 0) { throw 'Selected edge was not removed.' }
            Add-WorkflowEdge ([string]$script:CurrentWorkflow.Nodes[0].Id) ([string]$script:CurrentWorkflow.Nodes[1].Id)
            $originalEndY = $script:CurrentWorkflow.Nodes[1].Y
            $script:CurrentWorkflow.Nodes[1].Y = 210
            if ($null -eq (Get-EdgeAt 310 196)) { throw 'Diagonal edge hit testing failed.' }
            $script:CurrentWorkflow.Nodes[1].Y = $originalEndY
            $script:SmokeStage='canvas-copy-paste'
            $copySource=New-WorkflowNode 'Delay' '复制测试' 220 280 ([pscustomobject]@{Seconds=2})
            $script:CurrentWorkflow.Nodes=@($script:CurrentWorkflow.Nodes)+$copySource
            $script:SelectedNode=$copySource
            if(-not(Copy-SelectedCanvasNode)){throw 'Canvas node copy failed.'}
            $pastedNode=Paste-CopiedCanvasNode ([pscustomobject]@{X=520;Y=320})
            if($null-eq$pastedNode-or[string]$pastedNode.Id-eq[string]$copySource.Id-or$pastedNode.X-ne520-or$pastedNode.Y-ne320-or$pastedNode.Config.Seconds-ne2){throw 'Canvas node paste did not clone configuration or position.'}
            $script:SmokeStage = 'duplicate-node-delete'; $duplicateStart = New-WorkflowNode 'Start' '重复开始' 20 20
            $script:CurrentWorkflow.Nodes = @($script:CurrentWorkflow.Nodes) + $duplicateStart
            $script:SelectedNode = $duplicateStart
            Remove-SelectedNode
            if (@($script:CurrentWorkflow.Nodes | Where-Object Type -eq 'Start').Count -ne 1) { throw 'Duplicate start node was not removable.' }
            $duplicateEnd = New-WorkflowNode 'End' '重复结束' 400 20
            $script:CurrentWorkflow.Nodes = @($script:CurrentWorkflow.Nodes) + $duplicateEnd
            $script:SelectedNode = $duplicateEnd
            Remove-SelectedNode
            if (@($script:CurrentWorkflow.Nodes | Where-Object Type -eq 'End').Count -ne 1) { throw 'Duplicate end node was not removable.' }
            $script:SmokeStage = 'canvas-drag'; $mouseDownArgs = [object[]]@([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, 80, 130, 0))
            $mouseMoveArgs = [object[]]@([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 0, 120, 160, 0))
            $blankMouseArgs = [object[]]@([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, 10, 10, 0))
            $mouseMove = $script:Canvas.GetType().GetMethod('OnMouseMove', [Reflection.BindingFlags]'Instance,NonPublic')
            $mouseUp = $script:Canvas.GetType().GetMethod('OnMouseUp', [Reflection.BindingFlags]'Instance,NonPublic')
            $mouseDown.Invoke($script:Canvas, $mouseDownArgs) | Out-Null
            $script:Canvas.Refresh()
            if ($null -ne $script:CanvasRenderError) { throw ('Canvas repaint after selection failed: ' + $script:CanvasRenderError) }
            $mouseMove.Invoke($script:Canvas, $mouseMoveArgs) | Out-Null
            $script:Canvas.Refresh()
            if ($null -ne $script:CanvasRenderError) { throw ('Canvas repaint while dragging failed: ' + $script:CanvasRenderError) }
            $mouseUp.Invoke($script:Canvas, $mouseMoveArgs) | Out-Null
            $mouseDown.Invoke($script:Canvas, $blankMouseArgs) | Out-Null
            $script:Canvas.Refresh()
            if ($null -ne $script:CanvasRenderError) { throw ('Canvas repaint after blank click failed: ' + $script:CanvasRenderError) }
        } catch { $script:SmokeError = "stage=$($script:SmokeStage); $($_.Exception.Message); stack=$($_.ScriptStackTrace)" }
        if($null-eq$script:SmokeError){Write-WorkflowLog ('UI_SMOKE_ASSERTIONS_PASSED stage='+$script:SmokeStage)}else{Write-WorkflowLog ('UI_SMOKE_ASSERTIONS_FAILED '+$script:SmokeError) 'ERROR'}
        $script:SmokeTimer.Stop()
        Exit-WorkflowManager
    })
    $script:SmokeTimer.Start()
    $managerOutput=@(Show-WorkflowManager)
    if($managerOutput.Count-ne0){throw ('UI startup emitted unexpected output: '+(($managerOutput|ForEach-Object{[string]$_})-join', '))}
    if ($null -ne $script:SmokeError) { throw "UI smoke test failed: $script:SmokeError" }
    if (Test-Path -LiteralPath $testDirectory) { [IO.Directory]::Delete($testDirectory, $true) }
    Write-Output 'UI smoke test passed: workflow list, conversation file tree, canvas, tray host, scheduler, and logs.'
}

function Invoke-WorkflowTrayPersistenceTest {
    $testDirectory = Join-Path $env:TEMP ('PowerUI-WorkflowTrayTest-' + $PID)
    $script:DataDirectory = $testDirectory
    $script:WorkflowPath = Join-Path $testDirectory 'workflows.json'
    $script:ProjectPath = Join-Path $testDirectory 'projects.json'
    $script:SettingsPath = Join-Path $testDirectory 'settings.json'
    $script:LogDirectory = Join-Path $testDirectory 'logs'
    $script:LogPath = Join-Path $script:LogDirectory 'tray-test.log'
    $script:WorkflowAiDirectory = Join-Path $testDirectory 'workflow-ai'
    $script:EmbeddedWorkflowSkillPath = Join-Path $script:WorkflowAiDirectory 'skills\workflow-manager'
    $script:Projects = @()
    $script:GlobalSettings = New-DefaultGlobalSettings
    $script:Workflows = @((New-DefaultWorkflow))
    $script:TrayTestError = $null
    $script:TrayTestStage = 0
    $script:TrayTestHiddenAt = [datetime]::MinValue
    $script:TrayTestWindowHandle = [IntPtr]::Zero
    $script:TrayTestDurationSeconds = 6
    $requestedDuration = [Environment]::GetEnvironmentVariable('POWERUI_WORKFLOW_TRAY_TEST_SECONDS', 'Process')
    $parsedDuration = 0
    if ([int]::TryParse($requestedDuration, [ref]$parsedDuration)) { $script:TrayTestDurationSeconds = [Math]::Min(120, [Math]::Max(2, $parsedDuration)) }
    $script:TrayTestTimer = New-Object System.Windows.Forms.Timer
    $script:TrayTestTimer.Interval = 500
    $script:TrayTestTimer.Add_Tick({
        try {
            if ($script:TrayTestStage -eq 0) {
                if ($null -eq $script:MainForm -or -not $script:MainForm.Visible) { return }
                if (-not $script:MainForm.ShowIcon -or $null -eq $script:MainForm.Icon -or $script:MainForm.Icon.Handle -eq [IntPtr]::Zero) { throw 'The title-bar icon is unavailable.' }
                if ([WorkflowNativeMethods]::GetWindowIcon($script:MainForm, $false) -eq [IntPtr]::Zero -or [WorkflowNativeMethods]::GetWindowIcon($script:MainForm, $true) -eq [IntPtr]::Zero) { throw 'Native window icon handles are unavailable.' }
                if ($null -eq $script:NotifyIcon.Icon -or $script:NotifyIcon.Icon.Handle -eq [IntPtr]::Zero) { throw 'The tray icon is unavailable.' }
                $script:TrayTestWindowHandle = $script:MainForm.Handle
                $script:MainForm.Close()
                if ($script:MainForm.IsDisposed -or $script:MainForm.Visible -or -not $script:MainForm.ShowInTaskbar -or $script:MainForm.Handle -ne $script:TrayTestWindowHandle) { throw "Closing the window recreated or disposed it instead of hiding smoothly: disposed=$($script:MainForm.IsDisposed), visible=$($script:MainForm.Visible), handle=$($script:MainForm.Handle)." }
                $script:TrayTestHiddenAt = Get-Date
                $script:TrayTestStage = 1
                return
            }
            if ($script:TrayTestStage -eq 1 -and ((Get-Date) - $script:TrayTestHiddenAt).TotalSeconds -lt $script:TrayTestDurationSeconds) { return }
            if (-not [Windows.Forms.Application]::MessageLoop) { throw 'The application message loop stopped while hidden.' }
            if ($null -eq $script:ApplicationContext) { throw 'The application context was released while hidden.' }
            if ($script:MainForm.IsDisposed -or $script:MainForm.Visible) { throw 'The hidden main window lifecycle is invalid.' }
            if ($null -eq $script:SchedulerTimer -or -not $script:SchedulerTimer.Enabled) { throw 'The scheduler stopped while hidden.' }
            if ($null -eq $script:NotifyIcon -or -not $script:NotifyIcon.Visible -or $null -eq $script:NotifyIcon.Icon) { throw 'The tray icon did not persist.' }
            Restore-WorkflowManagerFromTray
            if (-not $script:MainForm.Visible -or -not $script:MainForm.ShowInTaskbar -or $script:MainForm.Handle -ne $script:TrayTestWindowHandle) { throw 'The main window could not be restored with the same handle.' }
        } catch {
            $script:TrayTestError = $_.Exception.Message
        }
        $script:TrayTestTimer.Stop()
        Exit-WorkflowManager
    })
    try {
        $script:TrayTestTimer.Start()
        Show-WorkflowManager
    } finally {
        $script:TrayTestTimer.Stop()
        $script:TrayTestTimer.Dispose()
        $script:TrayTestTimer = $null
    }
    if ($null -ne $script:TrayTestError) { throw "Tray persistence test failed: $script:TrayTestError" }
    if (Test-Path -LiteralPath $testDirectory) { [IO.Directory]::Delete($testDirectory, $true) }
    Write-Output "Tray persistence test passed: close-to-tray remained alive and restored after $script:TrayTestDurationSeconds seconds."
}

function Invoke-WorkflowNetworkSelfTest {
    $testDirectory = Join-Path $env:TEMP ('PowerUI-WorkflowNetworkTest-' + $PID)
    $script:DataDirectory = $testDirectory
    $script:WorkflowPath = Join-Path $testDirectory 'workflows.json'
    $script:ProjectPath = Join-Path $testDirectory 'projects.json'
    $script:SettingsPath = Join-Path $testDirectory 'settings.json'
    $script:LogDirectory = Join-Path $testDirectory 'logs'
    $script:LogPath = Join-Path $script:LogDirectory 'network.log'
    $script:WorkflowAiDirectory = Join-Path $testDirectory 'workflow-ai'
    $script:EmbeddedWorkflowSkillPath = Join-Path $script:WorkflowAiDirectory 'skills\workflow-manager'
    Ensure-DataDirectories
    $start = New-WorkflowNode 'Start' '开始' 20 20
    $http = New-WorkflowNode 'HttpRequest' '公开配置请求' 240 20 ([pscustomobject]@{ Method = 'GET'; Url = 'https://new.sharedchat.cc/frontend-api/getConfig'; Headers = '{}'; Body = ''; ResponseVar = 'config'; ExpectedCode = '1' })
    $end = New-WorkflowNode 'End' '结束' 460 20
    $workflow = [pscustomobject]@{ Id = 'network-test'; Name = 'Network test'; Nodes = @($start,$http,$end); Edges = @((New-WorkflowEdge $start.Id $http.Id),(New-WorkflowEdge $http.Id $end.Id)) }
    $worker = Start-WorkerProcess $workflow
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $worker.Process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (-not $worker.Process.HasExited) { Stop-Process -Id $worker.Process.Id -Force -ErrorAction SilentlyContinue; throw 'Network self-test timed out.' }
    $lines = @()
    if (Test-Path -LiteralPath $worker.OutputPath) { $lines = @((Read-TextFileWithRetry $worker.OutputPath) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    $events = @($lines | ForEach-Object { [string]$_ | ConvertFrom-Json })
    foreach ($path in @($worker.InputPath,$worker.OutputPath,$worker.ErrorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    if (@($events | Where-Object Kind -eq 'Done').Count -ne 1) { throw (($events | ConvertTo-Json -Depth 8)) }
    if (Test-Path -LiteralPath $testDirectory) { [IO.Directory]::Delete($testDirectory, $true) }
    Write-Output 'Network self-test passed: packaged worker HTTPS request and business code validation.'
}

function Invoke-WorkflowWebSelfTest {
    $testDirectory = Join-Path $env:TEMP ('PowerUI-WorkflowWebTest-' + $PID)
    $script:DataDirectory = $testDirectory
    $script:WorkflowPath = Join-Path $testDirectory 'workflows.json'
    $script:ProjectPath = Join-Path $testDirectory 'projects.json'
    $script:SettingsPath = Join-Path $testDirectory 'settings.json'
    $script:LogDirectory = Join-Path $testDirectory 'logs'
    $script:LogPath = Join-Path $script:LogDirectory 'web.log'
    $script:WorkflowAiDirectory = Join-Path $testDirectory 'workflow-ai'
    $script:EmbeddedWorkflowSkillPath = Join-Path $script:WorkflowAiDirectory 'skills\workflow-manager'
    $script:Projects = @()
    $script:Workflows = @()
    $script:RunningJobs = @{}
    $script:GlobalSettings = New-DefaultGlobalSettings
    $script:GlobalSettings.WebEnabled = $true
    $script:GlobalSettings.WebAccessCode = 'web-self-test-code'
    Ensure-DataDirectories
    $webProject=New-Project 'powerUI' $testDirectory 'web-session-id' '' @([pscustomobject]@{SessionId='web-session-id';CodexModel='';Description='默认主会话'})
    $ungroupedWorkflow=New-DefaultWorkflow 'Web 无项目任务' ''
    $script:Projects=@($webProject)
    $script:Workflows=@($ungroupedWorkflow)
    $server = New-Object WorkflowApiServer
    $server.ServerName = 'web'
    $script:WebApiServer = $server
    try {
        $server.Start('0.0.0.0', 0)
        function Send-WebSelfTestRequest {
            param([string]$Method, [string]$Target, [string]$Body = '', [string]$Token = '')
            $client = New-Object Net.Sockets.TcpClient
            $reader = $null
            try {
                $client.Connect('127.0.0.1', $script:WebApiServer.Port)
                $stream = $client.GetStream()
                $lines = @($Method + ' ' + $Target + ' HTTP/1.1','Host: 127.0.0.1:' + $script:WebApiServer.Port,'Connection: close')
                if (-not [string]::IsNullOrWhiteSpace($Token)) { $lines += 'Authorization: Bearer ' + $Token }
                if (-not [string]::IsNullOrWhiteSpace($Body)) { $lines += 'Content-Type: application/json'; $lines += 'Content-Length: ' + ([Text.Encoding]::UTF8.GetByteCount($Body)) }
                $newLine = [string][char]13 + [char]10
                $requestText = ($lines -join $newLine) + $newLine + $newLine + $Body
                $bytes = [Text.Encoding]::UTF8.GetBytes($requestText); $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
                $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
                $task = $reader.ReadToEndAsync(); $deadline = (Get-Date).AddSeconds(10)
                while (-not $task.IsCompleted -and (Get-Date) -lt $deadline) { Invoke-PendingWorkflowWebRequests; Start-Sleep -Milliseconds 20 }
                if (-not $task.IsCompleted) { throw 'Web HTTP self-test timed out.' }
                $responseText = [string]$task.Result; $parts = $responseText -split ($newLine + $newLine),2; $status = [int](($parts[0] -split ' ')[1]); $responseBody = if($parts.Count -gt 1){$parts[1]}else{''}
                return [pscustomobject]@{StatusCode=$status;Body=$responseBody}
            } finally { if($null-ne$reader){$reader.Dispose()};$client.Dispose() }
        }
        $page = Send-WebSelfTestRequest 'GET' '/web'
        if ($page.StatusCode -ne 200) { throw 'Web login page was not reachable.' }
        if($page.Body.IndexOf('const asArray=',[StringComparison]::Ordinal)-lt0-or$page.Body.IndexOf("event.ctrlKey",[StringComparison]::Ordinal)-lt0-or$page.Body.IndexOf('Ctrl+Enter',[StringComparison]::Ordinal)-lt0){throw 'Web page is missing singleton-array compatibility or Ctrl+Enter sending.'}
        if($page.Body.IndexOf('''_ungrouped''',[StringComparison]::Ordinal)-lt0){throw 'Web page is missing the canonical ungrouped project route.'}
        $unauthorized = Send-WebSelfTestRequest 'GET' '/web/api/bootstrap'
        if ($unauthorized.StatusCode -ne 401) { throw 'Web unauthorized request was not rejected.' }
        $badLogin = Send-WebSelfTestRequest 'POST' '/web/api/auth/login' ([pscustomobject]@{accessCode='wrong'}|ConvertTo-Json -Compress)
        if ($badLogin.StatusCode -ne 401) { throw 'Web invalid access code was not rejected.' }
        $login = Send-WebSelfTestRequest 'POST' '/web/api/auth/login' ([pscustomobject]@{accessCode='web-self-test-code'}|ConvertTo-Json -Compress)
        if ($login.StatusCode -ne 200) { throw 'Web login failed.' }
        $token = [string](($login.Body|ConvertFrom-Json).data.token)
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Web login did not return a token.' }
        $bootstrap = Send-WebSelfTestRequest 'GET' '/web/api/bootstrap' '' $token
        if ($bootstrap.StatusCode -ne 200 -or -not (($bootstrap.Body|ConvertFrom-Json).ok)) { throw 'Web authenticated bootstrap failed.' }
        $bootstrapData=($bootstrap.Body|ConvertFrom-Json).data
        $powerUiItem=@($bootstrapData.projects|Where-Object name -eq 'powerUI'|Select-Object -First 1)
        if($powerUiItem.Count-ne1-or@($powerUiItem[0].codexSessions).Count-ne1-or[string]$powerUiItem[0].codexSessions[0].sessionKey-ne'web-session-id'){throw 'Web bootstrap did not expose the project session.'}
        $ungroupedItem=@($bootstrapData.projects|Where-Object{[string]$_.id-eq''}|Select-Object -First 1)
        if($ungroupedItem.Count-ne1-or@($ungroupedItem[0].workflows).Count-ne1-or[string]$ungroupedItem[0].workflows[0].id-ne[string]$ungroupedWorkflow.Id){throw 'Web bootstrap did not expose the ungrouped workflow.'}
        $ungroupedList=Send-WebSelfTestRequest 'GET' '/web/api/projects/_ungrouped/workflows' '' $token
        if($ungroupedList.StatusCode-ne200-or@((($ungroupedList.Body|ConvertFrom-Json).data.workflows)).Count-ne1){throw 'Web ungrouped workflow list route failed.'}
        $ungroupedRun=Send-WebSelfTestRequest 'POST' ('/web/api/projects/_ungrouped/workflows/'+[string]$ungroupedWorkflow.Id+'/run') '{}' $token
        if($ungroupedRun.StatusCode-ne200-or-not$script:RunningJobs.ContainsKey([string]$ungroupedWorkflow.Id)){throw 'Web ungrouped workflow run route failed.'}
        $ungroupedStop=Send-WebSelfTestRequest 'POST' ('/web/api/projects/_ungrouped/workflows/'+[string]$ungroupedWorkflow.Id+'/stop') '{}' $token
        if($ungroupedStop.StatusCode-ne200){throw 'Web ungrouped workflow stop route failed.'}
        $ungroupedLegacyStop=Send-WebSelfTestRequest 'POST' ('/web/api/workflows/'+[string]$ungroupedWorkflow.Id+'/stop') '{}' $token
        if($ungroupedLegacyStop.StatusCode-ne200){throw 'Web legacy ungrouped workflow route failed.'}
        $newSession=Send-WebSelfTestRequest 'POST' ('/web/api/projects/'+[string]$webProject.Id+'/sessions') ([pscustomobject]@{description='Web temporary';model='gpt-web'}|ConvertTo-Json -Compress) $token
        if($newSession.StatusCode-ne201-or[string](($newSession.Body|ConvertFrom-Json).data.sessionKey)-ne'_new-1'){throw 'Web new-session endpoint did not create an indexed pending session.'}
        $pendingDetail=Send-WebSelfTestRequest 'GET' ('/web/api/projects/'+[string]$webProject.Id+'/sessions/_new-1') '' $token
        if($pendingDetail.StatusCode-ne200-or[string](($pendingDetail.Body|ConvertFrom-Json).data.description)-ne'Web temporary'){throw 'Web pending-session detail endpoint did not resolve the selected row.'}
        $sessionStatus=Send-WebSelfTestRequest 'GET' ('/web/api/projects/'+[string]$webProject.Id+'/sessions/web-session-id/status') '' $token
        if($sessionStatus.StatusCode-ne200-or[string](($sessionStatus.Body|ConvertFrom-Json).data.status)-ne'已完成'){throw 'Web session-status endpoint failed.'}
        $emptyMessage=Send-WebSelfTestRequest 'POST' ('/web/api/projects/'+[string]$webProject.Id+'/sessions/web-session-id/messages') ([pscustomobject]@{message=''}|ConvertTo-Json -Compress) $token
        if($emptyMessage.StatusCode-ne400){throw 'Web message endpoint did not validate empty messages.'}
    } finally {
        if($script:RunningJobs.Count-gt0){try{Stop-AllWorkflowJobs}catch{}}
        try { $server.Dispose() } catch { }
        $script:WebApiServer = $null
        $script:WebApiSessions = @{}
        if (Test-Path -LiteralPath $testDirectory) { [IO.Directory]::Delete($testDirectory, $true) }
    }
    Write-Output 'Web self-test passed: page, access-code login, bearer authentication, and bootstrap.'
}

$environmentTestMode = [Environment]::GetEnvironmentVariable('POWERUI_WORKFLOW_TEST_MODE', 'Process')
if ($environmentTestMode -eq 'SelfTest') { Invoke-WorkflowSelfTest | Out-Null; exit 0 }
if ($environmentTestMode -eq 'UiSmokeTest') { Invoke-WorkflowUiSmokeTest | Out-Null; exit 0 }
if ($environmentTestMode -eq 'NetworkSelfTest') { Invoke-WorkflowNetworkSelfTest | Out-Null; exit 0 }
if ($environmentTestMode -eq 'TrayPersistenceTest') { Invoke-WorkflowTrayPersistenceTest | Out-Null; exit 0 }
if ($environmentTestMode -eq 'WebSelfTest') { Invoke-WorkflowWebSelfTest | Out-Null; exit 0 }
if ($SelfTest) { try { Invoke-WorkflowSelfTest; exit 0 } catch { [Console]::Error.WriteLine(('SelfTest failed: '+$_.Exception.Message+'; stack='+$_.ScriptStackTrace)); exit 1 } }
if ($UiSmokeTest) { Invoke-WorkflowUiSmokeTest; exit 0 }
if ($NetworkSelfTest) { Invoke-WorkflowNetworkSelfTest; exit 0 }
if ($TrayPersistenceTest) { Invoke-WorkflowTrayPersistenceTest; exit 0 }
if ($WebSelfTest) { Invoke-WorkflowWebSelfTest; exit 0 }

if (-not (Initialize-SingleInstance)) { exit 0 }
try {
    [void](Ensure-DataDirectories)
    $script:Projects = @(Load-Projects)
    $script:GlobalSettings = Load-GlobalSettings
    $script:Workflows = @(Load-Workflows)
    [void](Upgrade-MainBranchBuildWorkflow)
    [void](Upgrade-RestartWorkflow)
    [void](Install-BuiltInWorkflowExamples)
    [void](Show-WorkflowManager)
} finally {
    [void](Release-SingleInstance)
}
