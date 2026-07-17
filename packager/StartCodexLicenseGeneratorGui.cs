using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    private const string ProductName = "Start-Codex-Final";

    [STAThread]
    private static void Main(string[] args)
    {
        if (TryRunFileMode(args))
        {
            return;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new LicenseGeneratorForm());
    }

    private static bool TryRunFileMode(string[] args)
    {
        if (args.Length == 0 || !String.Equals(args[0], "--cli-generate", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string customer = "";
        string machineId = "ANY";
        int days = 0;
        string outFile = "";

        for (int i = 1; i < args.Length; i++)
        {
            string key = args[i];
            string value = i + 1 < args.Length ? args[i + 1] : "";
            if (String.Equals(key, "--customer", StringComparison.OrdinalIgnoreCase))
            {
                customer = value;
                i++;
            }
            else if (String.Equals(key, "--machine-id", StringComparison.OrdinalIgnoreCase))
            {
                machineId = value;
                i++;
            }
            else if (String.Equals(key, "--days", StringComparison.OrdinalIgnoreCase))
            {
                Int32.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out days);
                i++;
            }
            else if (String.Equals(key, "--out", StringComparison.OrdinalIgnoreCase))
            {
                outFile = value;
                i++;
            }
        }

        if (String.IsNullOrWhiteSpace(customer) || String.IsNullOrWhiteSpace(outFile))
        {
            return true;
        }

        string expiresUtc = days > 0 ? DateTime.UtcNow.AddDays(days).ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture) : "";
        LicenseResult result = LicenseMaker.Generate(customer, machineId, expiresUtc);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outFile)));
        File.WriteAllText(outFile, result.ToText(), new UTF8Encoding(false));
        return true;
    }
}

internal sealed class LicenseGeneratorForm : Form
{
    private readonly TextBox customerBox = new TextBox();
    private readonly CheckBox bindMachineBox = new CheckBox();
    private readonly TextBox machineBox = new TextBox();
    private readonly RadioButton noExpiryRadio = new RadioButton();
    private readonly RadioButton daysRadio = new RadioButton();
    private readonly NumericUpDown daysBox = new NumericUpDown();
    private readonly RadioButton dateRadio = new RadioButton();
    private readonly DateTimePicker expiryPicker = new DateTimePicker();
    private readonly Button generateButton = new Button();
    private readonly Button copyCodeButton = new Button();
    private readonly Button copyAllButton = new Button();
    private readonly Button saveButton = new Button();
    private readonly TextBox resultBox = new TextBox();
    private readonly Label keyStatusLabel = new Label();
    private LicenseResult lastResult;

    public LicenseGeneratorForm()
    {
        Text = "Start-Codex-Final 授权码生成器";
        MinimumSize = new Size(860, 660);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
        BackColor = Color.FromArgb(248, 249, 251);

        BuildLayout();
        RefreshPrivateKeyStatus();
        UpdateControlState();
    }

    private void BuildLayout()
    {
        TableLayoutPanel root = new TableLayoutPanel();
        root.Dock = DockStyle.Fill;
        root.ColumnCount = 1;
        root.RowCount = 4;
        root.Padding = new Padding(18);
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 62));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 252));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(root);

        Panel header = new Panel();
        header.Dock = DockStyle.Fill;
        Label title = new Label();
        title.Text = "授权码生成器";
        title.Font = new Font(Font.FontFamily, 18F, FontStyle.Bold);
        title.ForeColor = Color.FromArgb(30, 41, 59);
        title.AutoSize = true;
        title.Location = new Point(0, 0);
        header.Controls.Add(title);

        keyStatusLabel.AutoSize = true;
        keyStatusLabel.Location = new Point(2, 38);
        header.Controls.Add(keyStatusLabel);
        root.Controls.Add(header, 0, 0);

        TableLayoutPanel formGrid = new TableLayoutPanel();
        formGrid.Dock = DockStyle.Fill;
        formGrid.ColumnCount = 2;
        formGrid.RowCount = 5;
        formGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120));
        formGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        formGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        formGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        formGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        formGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        formGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        root.Controls.Add(formGrid, 0, 1);

        AddLabel(formGrid, "客户名称", 0);
        customerBox.Dock = DockStyle.Fill;
        customerBox.Margin = new Padding(0, 5, 0, 7);
        customerBox.PlaceholderTextCompat("例如：客户A / 张三 / 公司名");
        formGrid.Controls.Add(customerBox, 1, 0);

        AddLabel(formGrid, "机器绑定", 1);
        FlowLayoutPanel machinePanel = new FlowLayoutPanel();
        machinePanel.Dock = DockStyle.Fill;
        machinePanel.FlowDirection = FlowDirection.LeftToRight;
        machinePanel.WrapContents = false;
        machinePanel.Margin = new Padding(0, 4, 0, 4);
        bindMachineBox.Text = "绑定机器码";
        bindMachineBox.AutoSize = true;
        bindMachineBox.Margin = new Padding(0, 8, 10, 0);
        bindMachineBox.CheckedChanged += delegate { UpdateControlState(); };
        machineBox.Width = 430;
        machineBox.Margin = new Padding(0, 4, 8, 0);
        machineBox.PlaceholderTextCompat("不绑定请留空；绑定时粘贴客户机器码");
        Button pasteMachineButton = new Button();
        pasteMachineButton.Text = "粘贴";
        pasteMachineButton.Width = 72;
        pasteMachineButton.Height = 28;
        pasteMachineButton.Margin = new Padding(0, 3, 0, 0);
        pasteMachineButton.Click += delegate
        {
            if (Clipboard.ContainsText())
            {
                machineBox.Text = Clipboard.GetText().Trim();
                bindMachineBox.Checked = true;
            }
        };
        machinePanel.Controls.Add(bindMachineBox);
        machinePanel.Controls.Add(machineBox);
        machinePanel.Controls.Add(pasteMachineButton);
        formGrid.Controls.Add(machinePanel, 1, 1);

        AddLabel(formGrid, "有效期", 2);
        FlowLayoutPanel expiryPanel = new FlowLayoutPanel();
        expiryPanel.Dock = DockStyle.Fill;
        expiryPanel.WrapContents = false;
        expiryPanel.Margin = new Padding(0, 4, 0, 4);
        noExpiryRadio.Text = "永久";
        noExpiryRadio.AutoSize = true;
        noExpiryRadio.Checked = true;
        noExpiryRadio.Margin = new Padding(0, 8, 18, 0);
        daysRadio.Text = "按天数";
        daysRadio.AutoSize = true;
        daysRadio.Margin = new Padding(0, 8, 8, 0);
        daysBox.Minimum = 1;
        daysBox.Maximum = 36500;
        daysBox.Value = 30;
        daysBox.Width = 82;
        daysBox.Margin = new Padding(0, 5, 18, 0);
        dateRadio.Text = "到期日";
        dateRadio.AutoSize = true;
        dateRadio.Margin = new Padding(0, 8, 8, 0);
        expiryPicker.Width = 142;
        expiryPicker.Format = DateTimePickerFormat.Custom;
        expiryPicker.CustomFormat = "yyyy-MM-dd";
        expiryPicker.Value = DateTime.Today.AddMonths(1);
        expiryPicker.Margin = new Padding(0, 5, 0, 0);
        noExpiryRadio.CheckedChanged += delegate { UpdateControlState(); };
        daysRadio.CheckedChanged += delegate { UpdateControlState(); };
        dateRadio.CheckedChanged += delegate { UpdateControlState(); };
        expiryPanel.Controls.Add(noExpiryRadio);
        expiryPanel.Controls.Add(daysRadio);
        expiryPanel.Controls.Add(daysBox);
        expiryPanel.Controls.Add(dateRadio);
        expiryPanel.Controls.Add(expiryPicker);
        formGrid.Controls.Add(expiryPanel, 1, 2);

        AddLabel(formGrid, "生成时间", 3);
        Label issuedHint = new Label();
        issuedHint.Text = "生成时自动写入当前 UTC 时间和唯一 License ID";
        issuedHint.AutoSize = true;
        issuedHint.ForeColor = Color.FromArgb(71, 85, 105);
        issuedHint.Margin = new Padding(0, 13, 0, 0);
        formGrid.Controls.Add(issuedHint, 1, 3);

        AddLabel(formGrid, "", 4);
        FlowLayoutPanel actionPanel = new FlowLayoutPanel();
        actionPanel.Dock = DockStyle.Fill;
        actionPanel.WrapContents = false;
        actionPanel.Margin = new Padding(0, 8, 0, 0);
        ConfigureButton(generateButton, "生成授权码", 116, true);
        ConfigureButton(copyCodeButton, "复制授权码", 100, false);
        ConfigureButton(copyAllButton, "复制全部", 88, false);
        ConfigureButton(saveButton, "保存文件", 88, false);
        generateButton.Click += delegate { GenerateLicense(); };
        copyCodeButton.Click += delegate { CopyCode(); };
        copyAllButton.Click += delegate { CopyAll(); };
        saveButton.Click += delegate { SaveLicense(); };
        actionPanel.Controls.Add(generateButton);
        actionPanel.Controls.Add(copyCodeButton);
        actionPanel.Controls.Add(copyAllButton);
        actionPanel.Controls.Add(saveButton);
        formGrid.Controls.Add(actionPanel, 1, 4);

        Label outputLabel = new Label();
        outputLabel.Text = "生成结果";
        outputLabel.Dock = DockStyle.Fill;
        outputLabel.Font = new Font(Font.FontFamily, 10F, FontStyle.Bold);
        outputLabel.ForeColor = Color.FromArgb(30, 41, 59);
        outputLabel.Margin = new Padding(0, 10, 0, 0);
        root.Controls.Add(outputLabel, 0, 2);

        resultBox.Dock = DockStyle.Fill;
        resultBox.Multiline = true;
        resultBox.ScrollBars = ScrollBars.Both;
        resultBox.WordWrap = false;
        resultBox.ReadOnly = false;
        resultBox.Font = new Font("Consolas", 10F, FontStyle.Regular, GraphicsUnit.Point);
        resultBox.BackColor = Color.White;
        resultBox.Margin = new Padding(0, 0, 0, 0);
        root.Controls.Add(resultBox, 0, 3);
    }

    private void AddLabel(TableLayoutPanel grid, string text, int row)
    {
        Label label = new Label();
        label.Text = text;
        label.Dock = DockStyle.Fill;
        label.TextAlign = ContentAlignment.MiddleLeft;
        label.Font = new Font(Font.FontFamily, 9F, FontStyle.Bold);
        label.ForeColor = Color.FromArgb(51, 65, 85);
        grid.Controls.Add(label, 0, row);
    }

    private void ConfigureButton(Button button, string text, int width, bool primary)
    {
        button.Text = text;
        button.Width = width;
        button.Height = 32;
        button.Margin = new Padding(0, 0, 10, 0);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 1;
        if (primary)
        {
            button.BackColor = Color.FromArgb(37, 99, 235);
            button.ForeColor = Color.White;
            button.FlatAppearance.BorderColor = Color.FromArgb(37, 99, 235);
        }
        else
        {
            button.BackColor = Color.White;
            button.ForeColor = Color.FromArgb(30, 41, 59);
            button.FlatAppearance.BorderColor = Color.FromArgb(203, 213, 225);
        }
    }

    private void RefreshPrivateKeyStatus()
    {
        if (LicenseMaker.HasEmbeddedPrivateKey)
        {
            keyStatusLabel.Text = "签名私钥已内嵌，生成器可独立运行";
            keyStatusLabel.ForeColor = Color.FromArgb(22, 101, 52);
        }
        else
        {
            keyStatusLabel.Text = "生成器未内嵌签名私钥，请重新打包";
            keyStatusLabel.ForeColor = Color.FromArgb(185, 28, 28);
        }
    }

    private void UpdateControlState()
    {
        machineBox.Enabled = bindMachineBox.Checked;
        daysBox.Enabled = daysRadio.Checked;
        expiryPicker.Enabled = dateRadio.Checked;
        copyCodeButton.Enabled = lastResult != null;
        copyAllButton.Enabled = lastResult != null;
        saveButton.Enabled = lastResult != null;
    }

    private void GenerateLicense()
    {
        try
        {
            string customer = customerBox.Text.Trim();
            if (String.IsNullOrWhiteSpace(customer))
            {
                MessageBox.Show(this, "请先填写客户名称。", "缺少客户名称", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                customerBox.Focus();
                return;
            }

            string machineId = bindMachineBox.Checked ? machineBox.Text.Trim() : "ANY";
            if (bindMachineBox.Checked && String.IsNullOrWhiteSpace(machineId))
            {
                MessageBox.Show(this, "已选择绑定机器码，请填写客户机器码。", "缺少机器码", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                machineBox.Focus();
                return;
            }

            string expiresUtc = "";
            if (daysRadio.Checked)
            {
                expiresUtc = DateTime.UtcNow.AddDays((int)daysBox.Value).ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
            }
            else if (dateRadio.Checked)
            {
                DateTime endOfDayLocal = expiryPicker.Value.Date.AddDays(1).AddSeconds(-1);
                expiresUtc = endOfDayLocal.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
            }

            lastResult = LicenseMaker.Generate(customer, machineId, expiresUtc);
            resultBox.Text = lastResult.ToText();
            UpdateControlState();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "生成失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void CopyCode()
    {
        if (lastResult == null)
        {
            return;
        }
        Clipboard.SetText(lastResult.AuthorizationCode);
    }

    private void CopyAll()
    {
        if (lastResult == null)
        {
            return;
        }
        Clipboard.SetText(lastResult.ToText());
    }

    private void SaveLicense()
    {
        if (lastResult == null)
        {
            return;
        }

        using (SaveFileDialog dialog = new SaveFileDialog())
        {
            dialog.Title = "保存授权码";
            dialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*";
            dialog.FileName = SanitizeFileName(lastResult.Customer) + "-授权码.txt";
            if (dialog.ShowDialog(this) == DialogResult.OK)
            {
                File.WriteAllText(dialog.FileName, lastResult.ToText(), new UTF8Encoding(false));
            }
        }
    }

    private static string SanitizeFileName(string value)
    {
        string name = String.IsNullOrWhiteSpace(value) ? "客户" : value.Trim();
        foreach (char c in Path.GetInvalidFileNameChars())
        {
            name = name.Replace(c, '_');
        }
        return name;
    }
}

internal static class LicenseMaker
{
    private const string ProductName = "Start-Codex-Final";
    private const string PrivateKeyXml = __PRIVATE_KEY_XML__;

    public static bool HasEmbeddedPrivateKey { get { return !String.IsNullOrWhiteSpace(PrivateKeyXml); } }

    public static LicenseResult Generate(string customer, string machineId, string expiresUtc)
    {
        if (!HasEmbeddedPrivateKey)
        {
            throw new InvalidOperationException("生成器中没有内嵌私钥，请重新运行打包脚本。 ");
        }

        if (String.IsNullOrWhiteSpace(machineId))
        {
            machineId = "ANY";
        }

        string licenseId = Guid.NewGuid().ToString("N").Substring(0, 16).ToUpperInvariant();
        string issuedUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
        string normalizedMachineId = machineId.Trim().ToUpperInvariant();

        string payload = String.Join("\n", new string[]
        {
            "product=" + ProductName,
            "licenseId=" + licenseId,
            "customer=" + customer,
            "issuedUtc=" + issuedUtc,
            "expiresUtc=" + (expiresUtc ?? ""),
            "machineId=" + normalizedMachineId
        });

        byte[] payloadBytes = Encoding.UTF8.GetBytes(payload);
        byte[] signature;

        CspParameters csp = new CspParameters();
        csp.ProviderType = 24;
        csp.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider";

        using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider(2048, csp))
        {
            rsa.PersistKeyInCsp = false;
            rsa.FromXmlString(PrivateKeyXml);
            signature = rsa.SignData(payloadBytes, CryptoConfig.MapNameToOID("SHA256"));
        }

        string authorizationCode = "SCF1." + Base64Url(payloadBytes) + "." + Base64Url(signature);

        return new LicenseResult
        {
            Customer = customer,
            LicenseId = licenseId,
            IssuedUtc = issuedUtc,
            ExpiresUtc = expiresUtc ?? "",
            MachineId = normalizedMachineId,
            AuthorizationCode = authorizationCode
        };
    }

    private static string Base64Url(byte[] bytes)
    {
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}

internal sealed class LicenseResult
{
    public string Customer { get; set; }
    public string LicenseId { get; set; }
    public string IssuedUtc { get; set; }
    public string ExpiresUtc { get; set; }
    public string MachineId { get; set; }
    public string AuthorizationCode { get; set; }

    public string ToText()
    {
        return "Customer: " + Customer + Environment.NewLine
            + "LicenseId: " + LicenseId + Environment.NewLine
            + "IssuedUtc: " + IssuedUtc + Environment.NewLine
            + "ExpiresUtc: " + ExpiresUtc + Environment.NewLine
            + "MachineId: " + MachineId + Environment.NewLine
            + Environment.NewLine
            + "AuthorizationCode:" + Environment.NewLine
            + AuthorizationCode + Environment.NewLine;
    }
}

internal static class TextBoxPlaceholderCompat
{
    public static void PlaceholderTextCompat(this TextBox textBox, string text)
    {
        try
        {
            textBox.GetType().GetProperty("PlaceholderText").SetValue(textBox, text, null);
        }
        catch
        {
            textBox.Tag = text;
        }
    }
}
