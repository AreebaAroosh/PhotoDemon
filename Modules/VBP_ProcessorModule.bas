Attribute VB_Name = "Processor"
'***************************************************************************
'Program Sub-Processor and Error Handler
'Copyright �2001-2013 by Tanner Helland
'Created: 4/15/01
'Last updated: 03/June/13
'Last update: started the painful process of rebuilding the software processor from scratch.  All params will now be string-based,
'              which introduces some overhead, but will make macro recording infinitely simpler.  It will also enable a filter browser,
'              which I have wanted since I first started work on PhotoDemon some 12 years ago.
'
'Module for controlling calls to the various program functions.  Any action the program takes has to pass
' through here.  Why go to all that extra work?  A couple of reasons:
' 1) a central error handler that works for every sub throughout the program (due to recursive error handling)
' 2) PhotoDemon can run macros by simply tracking the values that pass through this routine
' 3) PhotoDemon can control code flow by delaying requests that pass through here (for example,
'    if the program is busy applying a filter, we can wait to process subsequent calls)
' 4) miscellaneous semantic benefits
'
'Due to the nature of this routine, very little of interest happens here - this is primarily a router
' for various functions, so the majority of the routine is a huge Case Select statement.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://www.tannerhelland.com/photodemon/#license
'
'***************************************************************************

Option Explicit
Option Compare Text


'Data type for tracking processor calls - used for macros (NOTE: this is the 2013 model; older models are no longer supported.)
Public Type ProcessCall
    Id As String
    Dialog As Boolean
    Parameters As String
    MakeUndo As Boolean
    Recorded As Boolean
End Type

'During macro recording, all requests to the processor are stored in this array.
Public Processes() As ProcessCall

'How many processor requests we currently have stored.
Public ProcessCount As Long

'Full processor information of the previous request (used to provide a "Repeat Last Action" feature)
Public LastProcess As ProcessCall

'Track processing (e.g. whether or not the software processor is busy right now)
Public Processing As Boolean

'Elapsed time of this processor request (to enable this, see the top constant in the Public_Constants module)
Private m_ProcessingTime As Double

'PhotoDemon's software processor.  (Almost) every action the program takes is first routed through this method.  This processor is what
' makes recording and playing back macros possible, as well as a host of other features.  (See comment at top of page for more details.)
'
'INPUTS (asterisks denote optional parameters):
' - processID: a string identifying the action to be performed, e.g. "Blur"
' - *showDialog: some functions can be run with or without a dialog; for example, "Blur", "True" will display a blur settings dialog,
'                while "Blur", "False" will actually apply the blur.  If showDialog is true, no Undo will be created for the action.
' - *processParameters: all parameters for this function, concatenated into a single string.  The processor will automatically parse out
'                       individual parameters as necessary.
' - *createUndo: create an Undo entry for this action.  This is assumed TRUE for all actions, but some - like "Count image colors" must
'                explicitly specify that no Undo is necessary.  NOTE: if showDialog is TRUE, this value will automatically be set to FALSE.
' - *recordAction: are macros allowed to record this action?  Actions are assumed to be recordable.  However, some PhotoDemon functions
'                  are actually several actions strung together; when these are used, subsequent actions are marked as "not recordable"
'                  to prevent them from being executed twice.
Public Sub Process(ByVal processID As String, Optional ShowDialog As Boolean = False, Optional processParameters As String = "", Optional createUndo As Boolean = True, Optional RecordAction As Boolean = True)

    'Main error handler for the entire program is initialized by this line
    On Error GoTo MainErrHandler
    
    'If desired, this line can be used to artificially raise errors (to test the error handler)
    'Err.Raise 339
    
    'Mark the software processor as busy
    Processing = True
        
    'Disable the main form to prevent the user from clicking additional menus or tools while this one is processing
    FormMain.Enabled = False
    
    'If we need to display an additional dialog, restore the default mouse cursor.  Otherwise, set the cursor to busy.
    If ShowDialog Then
        If Not (FormMain.ActiveForm Is Nothing) Then setArrowCursor FormMain.ActiveForm
    Else
        Screen.MousePointer = vbHourglass
    End If
        
    'If we are to perform the last command, simply replace all the method parameters using data from the
    ' LastFilterCall object, then let the routine carry on as usual
    If processID = "Repeat last action" Then
        processID = LastProcess.Id
        ShowDialog = LastProcess.Dialog
        processParameters = LastProcess.Parameters
        RecordAction = LastProcess.Recorded
        createUndo = LastProcess.MakeUndo
    End If
    
    'If the macro recorder is running and this action is marked as recordable, store it in our array of processor calls
    If (MacroStatus = MacroSTART) And RecordAction Then
    
        'Increase the process count
        ProcessCount = ProcessCount + 1
        
        'Copy the current process's information into the tracking array
        ReDim Preserve Processes(0 To ProcessCount) As ProcessCall
        
        With Processes(ProcessCount)
            .Id = processID
            .Dialog = ShowDialog
            .Parameters = processParameters
            .Recorded = RecordAction
            .MakeUndo = createUndo
        End With
        
    End If
    
    'If a dialog is being displayed, disable Undo creation
    If ShowDialog Then createUndo = False
    
    'If this action requires us to create an Undo, create it now.  (We can also use this identifier to initiate a few
    ' other, related actions.)
    If createUndo Then
        
        'Temporarily disable drag-and-drop operations for the main form
        g_AllowDragAndDrop = False
        FormMain.OLEDropMode = 0
        
        'By default, actions are assumed to want Undo data created.  However, there are some known exceptions:
        ' 1) If a dialog is being displayed
        ' 2) If recording has been disabled for this action
        ' 3) If we are in the midst of playing back a recorded macro (Undo data takes extra time to process, so drop it)
        If MacroStatus <> MacroBATCH Then
            If (Not ShowDialog) And RecordAction Then CreateUndoFile processID
        End If
        
        'Save this information in the LastProcess variable (to be used if the user clicks on Edit -> Redo Last Action.
        FormMain.MnuRepeatLast.Enabled = True
        LastProcess.Id = processID
        LastProcess.Dialog = ShowDialog
        LastProcess.Parameters = processParameters
        LastProcess.Recorded = RecordAction
        LastProcess.MakeUndo = createUndo
        
        'If the user wants us to time how long this action takes, mark the current time now
        If Not ShowDialog Then
            If DISPLAY_TIMINGS Then m_ProcessingTime = Timer
        End If
        
    End If
    
    'Finally, create a parameter parser to handle the parameter string.  This class will parse out individual parameters
    ' as specific data types when it comes time to use them.
    Dim cParams As pdParamString
    Set cParams = New pdParamString
    If Len(processParameters) > 0 Then cParams.setParamString processParameters
    
    '******************************************************************************************************************
    '
    'BEGIN PROCESS SORTING
    '
    'The bulk of this routine starts here.  From this point on, the processID string is compared against a hard-coded
    ' list of every possible PhotoDemon action, filter, or other operation.  Depending on the processID, additional
    ' actions will be performed.
    '
    'Note that prior to the 5.6 release, this function used numeric identifiers instead of strings.  This has since
    ' been abandoned in favor of a string-based approach, and at present there are no plans to restore the old
    ' numeric behavior.  Strings simplify the code, they make it much easier to add new functions, and they will
    ' eventually allow for a "filter browser" that allows the user to preview any effect from a single dialog.
    ' Numeric IDs were much harder to manage in that context, and over time their numbering grew so arbitrary that
    ' it made maintenance very difficult.
    '
    'For ease of reference, the various processIDs are divided into categories of similar functions.  This
    ' organization is simply to improve readability; there is no functional purpose.
    '
    '******************************************************************************************************************
    
    Select Case processID
    
        'FILE MENU FUNCTIONS
        ' This includes actions like opening or saving images.  These actions are never recorded.
    
        Case "Open"
            MenuOpen
            
        Case "Save"
            MenuSave CurrentImage
            
        Case "Save as"
            MenuSaveAs CurrentImage
            
        Case "Screen capture"
            CaptureScreen
            
        Case "Copy to clipboard"
            ClipboardCopy
            
        Case "Paste as new image"
            ClipboardPaste
            
        Case "Empty clipboard"
            ClipboardEmpty
            
        Case "Undo"
            RestoreImage
            'Also, redraw the current child form icon
            CreateCustomFormIcon FormMain.ActiveForm
            
        Case "Redo"
            RedoImageRestore
            'Also, redraw the current child form icon
            CreateCustomFormIcon FormMain.ActiveForm
            
        Case "Start macro recording"
            StartMacro
        
        Case "Stop macro recording"
            StopMacro
            
        Case "Play macro"
            PlayMacro
            
        Case "Select scanner or camera"
            Twain32SelectScanner
            
        Case "Scan image"
            Twain32Scan
        
        'HISTOGRAM FUNCTIONS
        ' Any action that relies on a histogram, including displaying the image's current histogram
        Case "Display histogram"
            FormHistogram.Show 0, FormMain
        
        Case "Stretch histogram"
            FormHistogram.StretchHistogram
            
        Case "Equalize"
            If ShowDialog Then
                FormEqualize.Show vbModal, FormMain
            Else
                FormEqualize.EqualizeHistogram cParams.GetBool(1), cParams.GetBool(2), cParams.GetBool(3), cParams.GetBool(4)
            End If
            
        Case "White balance"
            If ShowDialog Then
                FormWhiteBalance.Show vbModal, FormMain
            Else
                FormWhiteBalance.AutoWhiteBalance cParams.GetDouble(1)
            End If
        
        'MONOCHROME CONVERSION
        'All monochrome conversion functions have been condensed into a single main one.  (Past versions spread it across multiple functions.)
        Case "Color to monochrome"
            If ShowDialog Then
                FormBlackAndWhite.Show vbModal, FormMain
            Else
                FormBlackAndWhite.masterBlackWhiteConversion cParams.GetLong(1), cParams.GetLong(2), cParams.GetLong(3), cParams.GetLong(4)
            End If
            
        Case "Monochrome to grayscale"
            If ShowDialog Then
                FormMonoToColor.Show vbModal, FormMain
            Else
                FormMonoToColor.ConvertMonoToColor cParams.GetLong(1)
            End If
        
        'GRAYSCALE conversion
        'PhotoDemon supports many types of grayscale conversion.
        Case "Desaturate"
            FormGrayscale.MenuDesaturate
            
        Case "Grayscale"
            FormGrayscale.Show vbModal, FormMain
            
        Case "Grayscale (ITU standard)"
            FormGrayscale.MenuGrayscale
            
        Case "Grayscale (average)"
            FormGrayscale.MenuGrayscaleAverage
            
        Case "Grayscale (custom # of colors)"
            FormGrayscale.fGrayscaleCustom cParams.GetLong(1)
            
        Case "Grayscale (custom dither)"
            FormGrayscale.fGrayscaleCustomDither cParams.GetLong(1)
            
        Case "Grayscale (decomposition)"
            FormGrayscale.MenuDecompose cParams.GetLong(1)
            
        Case "Grayscale (single channel)"
            FormGrayscale.MenuGrayscaleSingleChannel cParams.GetLong(1)
        
        'AREA filters
        Case "Sharpen"
            FilterSharpen
            
        Case "Sharpen more"
            FilterSharpenMore
            
        Case "Unsharp mask"
            If ShowDialog Then
                FormUnsharpMask.Show vbModal, FormMain
            Else
                FormUnsharpMask.UnsharpMask cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetLong(3)
            End If
            
        Case "Diffuse"
            If ShowDialog Then
                FormDiffuse.Show vbModal, FormMain
            Else
                FormDiffuse.DiffuseCustom cParams.GetLong(1), cParams.GetLong(2), cParams.GetBool(3)
            End If
            
        Case "Pixelate"
            If ShowDialog Then
                FormPixelate.Show vbModal, FormMain
            Else
                FormPixelate.PixelateFilter cParams.GetLong(1), cParams.GetLong(2)
            End If
            
        Case "Dilate (maximum rank)"
            If ShowDialog Then
                FormMedian.showMedianDialog 100
            Else
                FormMedian.ApplyMedianFilter cParams.GetLong(1), cParams.GetDouble(2)
            End If
            
        Case "Erode (minimum rank)"
            If ShowDialog Then
                FormMedian.showMedianDialog 1
            Else
                FormMedian.ApplyMedianFilter cParams.GetLong(1), cParams.GetDouble(2)
            End If
            
        Case "Grid blur"
            FilterGridBlur
            
        Case "Gaussian blur"
            If ShowDialog Then
                FormGaussianBlur.Show vbModal, FormMain
            Else
                FormGaussianBlur.GaussianBlurFilter cParams.GetDouble(1)
            End If
            
        Case "Smart blur"
            If ShowDialog Then
                FormSmartBlur.Show vbModal, FormMain
            Else
                FormSmartBlur.SmartBlurFilter cParams.GetDouble(1), cParams.GetByte(2), cParams.GetBool(3)
            End If
            
        Case "Box blur"
            If ShowDialog Then
                FormBoxBlur.Show vbModal, FormMain
            Else
                FormBoxBlur.BoxBlurFilter cParams.GetLong(1), cParams.GetLong(2)
            End If
        
        'EDGE filters
        Case "Emboss or engrave"
            FormEmbossEngrave.Show vbModal, FormMain
            
        Case "Emboss"
            FormEmbossEngrave.FilterEmbossColor cParams.GetLong(1)
            
        Case "Engrave"
            FormEmbossEngrave.FilterEngraveColor cParams.GetLong(1)
            
        Case "Pencil drawing"
            FilterPencil
            
        Case "Relief"
            FilterRelief
            
        Case "Artistic contour"
            FormFindEdges.FilterSmoothContour cParams.GetBool(1)
            
        Case "Find edges (Prewitt horizontal)"
            FormFindEdges.FilterPrewittHorizontal cParams.GetBool(1)
            
        Case "Find edges (Prewitt vertical)"
            FormFindEdges.FilterPrewittVertical cParams.GetBool(1)
            
        Case "Find edges (Sobel horizontal)"
            FormFindEdges.FilterSobelHorizontal cParams.GetBool(1)
            
        Case "Find edges (Sobel vertical)"
            FormFindEdges.FilterSobelVertical cParams.GetBool(1)
            
        Case "Find edges"
            FormFindEdges.Show vbModal, FormMain
            
        Case "Find edges (Laplacian)"
            FormFindEdges.FilterLaplacian cParams.GetBool(1)
            
        Case "Find edges (Hilite)"
            FormFindEdges.FilterHilite cParams.GetBool(1)
            
        Case "Find edges (PhotoDemon linear)"
            FormFindEdges.PhotoDemonLinearEdgeDetection cParams.GetBool(1)
            
        Case "Find edges (PhotoDemon cubic)"
            FormFindEdges.PhotoDemonCubicEdgeDetection cParams.GetBool(1)
            
        Case "Edge enhance"
            FilterEdgeEnhance
            
        Case "Trace contour"
            If ShowDialog Then
                FormContour.Show vbModal, FormMain
            Else
                FormContour.TraceContour cParams.GetLong(1), cParams.GetBool(2), cParams.GetBool(3)
            End If
        
        
        'COLOR operations
        Case "Rechannel"
            If ShowDialog Then
                FormRechannel.Show vbModal, FormMain
            Else
                FormRechannel.RechannelImage cParams.GetByte(1)
            End If
            
        Case "Shift colors (left)"
            MenuCShift 1
            
        Case "Shift colors (right)"
            MenuCShift 0
            
        Case "Brightness and contrast"
            If ShowDialog Then
                FormBrightnessContrast.Show vbModal, FormMain
            Else
                FormBrightnessContrast.BrightnessContrast cParams.GetLong(1), cParams.GetDouble(2), cParams.GetBool(3)
            End If
            
        Case "Gamma"
            If ShowDialog Then
                FormGamma.Show vbModal, FormMain
            Else
                FormGamma.GammaCorrect cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3)
            End If
            
        Case "Invert RGB"
            MenuInvert
            
        Case "Compound invert"
            MenuCompoundInvert cParams.GetLong(1)
            
        Case "Film negative"
            MenuNegative
            
        Case "Invert hue"
            MenuInvertHue
            
        Case "Auto-enhance contrast"
            MenuAutoEnhanceContrast
            
        Case "Auto-enhance highlights"
            MenuAutoEnhanceHighlights
            
        Case "Auto-enhance midtones"
            MenuAutoEnhanceMidtones
            
        Case "Auto-enhance shadows"
            MenuAutoEnhanceShadows
            
        Case "Levels"
            If ShowDialog Then
                FormLevels.Show vbModal, FormMain
            Else
                FormLevels.MapImageLevels cParams.GetLong(1), cParams.GetDouble(2), cParams.GetLong(3), cParams.GetLong(4), cParams.GetLong(5)
            End If
            
        Case "Colorize"
            If ShowDialog Then
                FormColorize.Show vbModal, FormMain
            Else
                FormColorize.ColorizeImage cParams.GetDouble(1), cParams.GetBool(2)
            End If
            
        Case "Reduce colors"
            If ShowDialog Then
                FormReduceColors.Show vbModal, FormMain
            Else
                Select Case cParams.GetLong(1)
                
                    Case REDUCECOLORS_AUTO
                        FormReduceColors.ReduceImageColors_Auto cParams.GetLong(2)
                
                    Case REDUCECOLORS_MANUAL
                        FormReduceColors.ReduceImageColors_BitRGB cParams.GetByte(2), cParams.GetByte(3), cParams.GetByte(4), cParams.GetBool(5)
                
                    Case REDUCECOLORS_MANUAL_ERRORDIFFUSION
                        FormReduceColors.ReduceImageColors_BitRGB_ErrorDif cParams.GetByte(2), cParams.GetByte(3), cParams.GetByte(4), cParams.GetBool(5)
                
                    Case Else
                        pdMsgBox "Unsupported color reduction method.", vbCritical + vbOKOnly + vbApplicationModal, "Color reduction error"
                End Select
            End If
            
        Case "Color temperature"
            If ShowDialog Then
                FormColorTemp.Show vbModal, FormMain
            Else
                FormColorTemp.ApplyTemperatureToImage cParams.GetLong(1), cParams.GetBool(2), cParams.GetDouble(3)
            End If
            
        Case "Hue and saturation"
            If ShowDialog Then
                FormHSL.Show vbModal, FormMain
            Else
                FormHSL.AdjustImageHSL cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3)
            End If
            
        Case "Color balance"
            If ShowDialog Then
                FormColorBalance.Show vbModal, FormMain
            Else
                FormColorBalance.ApplyColorBalance cParams.GetLong(1), cParams.GetLong(2), cParams.GetLong(3), cParams.GetBool(4)
            End If
            
        Case "Shadows and highlights"
            If ShowDialog Then
                FormShadowHighlight.Show vbModal, FormMain
            Else
                FormShadowHighlight.ApplyShadowHighlight cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetLong(3)
            End If
            
        Case "Channel mixer"
            If ShowDialog Then
                FormChannelMixer.Show vbModal, FormMain
            Else
                FormChannelMixer.ApplyChannelMixer cParams.getParamString
            End If
            
    
        'Coordinate filters/transformations
        Case "Flip vertical"
            MenuFlip
            
        Case "Arbitrary rotation"
            If ShowDialog Then
                FormRotate.Show vbModal, FormMain
            Else
                FormRotate.RotateArbitrary cParams.GetLong(1), cParams.GetDouble(2)
            End If
            
        Case "Flip horizontal"
            MenuMirror
            
        Case "Rotate 90� clockwise"
            MenuRotate90Clockwise
            
        Case "Rotate 180�"
            MenuRotate180
            
        Case "Rotate 90� counter-clockwise"
            MenuRotate270Clockwise
            
        Case "Isometric conversion"
            FilterIsometric
            
        Case "Canvas size"
            If ShowDialog Then
                'FormCanvasSize.Show vbModal, FormMain
            Else
            
            End If
            
        Case "Resize"
            If ShowDialog Then
                FormResize.Show vbModal, FormMain
            Else
                FormResize.ResizeImage cParams.GetLong(1), cParams.GetLong(2), cParams.GetByte(3)
            End If
            
        Case "Tile"
            If ShowDialog Then
                FormTile.Show vbModal, FormMain
            Else
                FormTile.GenerateTile cParams.GetByte(1), cParams.GetLong(2), cParams.GetLong(3)
            End If
            
        Case "Crop"
            MenuCropToSelection
            
        Case "Remove alpha channel"
            ConvertImageColorDepth 24
            
        Case "Add alpha channel"
            ConvertImageColorDepth 32
            
        Case "Swirl"
            If ShowDialog Then
                FormSwirl.Show vbModal, FormMain
            Else
                FormSwirl.SwirlImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetLong(3), cParams.GetBool(4)
            End If
            
        Case "Apply lens distortion"
            If ShowDialog Then
                FormLens.Show vbModal, FormMain
            Else
                FormLens.ApplyLensDistortion cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetBool(3)
            End If
            
        Case "Correct lens distortion"
            If ShowDialog Then
                FormLensCorrect.Show vbModal, FormMain
            Else
                FormLensCorrect.ApplyLensCorrection cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetLong(4), cParams.GetBool(5)
            End If
            
        Case "Ripple"
            If ShowDialog Then
                FormRipple.Show vbModal, FormMain
            Else
                FormRipple.RippleImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetDouble(4), cParams.GetLong(5), cParams.GetBool(6)
            End If
            
        Case "Pinch and whirl"
            If ShowDialog Then
                FormPinch.Show vbModal, FormMain
            Else
                FormPinch.PinchImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetLong(4), cParams.GetBool(5)
            End If
            
        Case "Waves"
            If ShowDialog Then
                FormWaves.Show vbModal, FormMain
            Else
                FormWaves.WaveImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetDouble(4), cParams.GetLong(5), cParams.GetBool(6)
            End If
            
        Case "Figured glass"
            If ShowDialog Then
                FormFiguredGlass.Show vbModal, FormMain
            Else
                FormFiguredGlass.FiguredGlassFX cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetLong(3), cParams.GetBool(4)
            End If
            
        Case "Kaleidoscope"
            If ShowDialog Then
                FormKaleidoscope.Show vbModal, FormMain
            Else
                FormKaleidoscope.KaleidoscopeImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetDouble(4), cParams.GetBool(5)
            End If
            
        Case "Polar conversion"
            If ShowDialog Then
                FormPolar.Show vbModal, FormMain
            Else
                FormPolar.ConvertToPolar cParams.GetLong(1), cParams.GetDouble(2), cParams.GetLong(3), cParams.GetBool(4)
            End If
            
        Case "Autocrop"
            AutocropImage
            
        Case "Shear"
            If ShowDialog Then
                FormShear.Show vbModal, FormMain
            Else
                FormShear.ShearImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetLong(3), cParams.GetBool(4)
            End If
            
        Case "Squish"
            If ShowDialog Then
                FormSquish.Show vbModal, FormMain
            Else
                FormSquish.SquishImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetLong(3), cParams.GetBool(4)
            End If
            
        Case "Perspective"
            If ShowDialog Then
                FormTruePerspective.Show vbModal, FormMain
            Else
                FormTruePerspective.PerspectiveImage cParams.getParamString
            End If
            
        Case "Pan and zoom"
            If ShowDialog Then
                FormPanAndZoom.Show vbModal, FormMain
            Else
                FormPanAndZoom.PanAndZoomFilter cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetLong(4), cParams.GetBool(5)
            End If
            
        Case "Poke"
            If ShowDialog Then
                FormPoke.Show vbModal, FormMain
            Else
                FormPoke.ApplyPokeDistort cParams.GetDouble(1), cParams.GetLong(2), cParams.GetBool(3)
            End If
            
        Case "Spherize"
            If ShowDialog Then
                FormSpherize.Show vbModal, FormMain
            Else
                FormSpherize.SpherizeImage cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetBool(4), cParams.GetLong(5), cParams.GetBool(6)
            End If
        
        Case "Miscellaneous distort"
            If ShowDialog Then
                FormMiscDistorts.Show vbModal, FormMain
            Else
                FormMiscDistorts.ApplyMiscDistort cParams.GetString(1), cParams.GetLong(2), cParams.GetLong(3), cParams.GetBool(4)
            End If
        
            
        'MISCELLANEOUS filters
        Case "Antique"
            MenuAntique
            
        Case "Atmosphere"
            MenuAtmospheric
            
        Case "Black light"
            If ShowDialog Then
                FormBlackLight.Show vbModal, FormMain
            Else
                FormBlackLight.fxBlackLight cParams.GetLong(1)
            End If
            
        Case "Dream"
            MenuDream
            
        Case "Posterize"
            If ShowDialog Then
                FormPosterize.Show vbModal, FormMain
            Else
                FormPosterize.PosterizeImage cParams.GetByte(1)
            End If
            
        Case "Radioactive"
            MenuRadioactive
            
        Case "Solarize"
            If ShowDialog Then
                FormSolarize.Show vbModal, FormMain
            Else
                FormSolarize.SolarizeImage cParams.GetByte(1)
            End If
            
        Case "Generate twins"
            If ShowDialog Then
                FormTwins.Show vbModal, FormMain
            Else
                FormTwins.GenerateTwins cParams.GetByte(1)
            End If
            
        Case "Fade"
            If ShowDialog Then
                FormFade.Show vbModal, FormMain
            Else
                FormFade.FadeImage cParams.GetDouble(1)
            End If
            
        Case "Unfade"
            FormFade.UnfadeImage
            
        Case "Alien"
            MenuAlien
            
        Case "Synthesize"
            MenuSynthesize
            
        Case "Water"
            MenuWater
            
        Case "Add RGB noise"
            If ShowDialog Then
                FormNoise.Show vbModal, FormMain
            Else
                FormNoise.AddNoise cParams.GetLong(1), cParams.GetBool(2)
            End If
            
        Case "Freeze"
            MenuFrozen
            
        Case "Lava"
            MenuLava
            
        Case "Custom filter"
            If ShowDialog Then
                FormCustomFilter.Show vbModal, FormMain
            Else
                DoFilter , , cParams.getParamString
            End If
            
        Case "Burn"
            MenuBurn
            
        Case "Steel"
            MenuSteel
            
        Case "Fog"
            MenuFogEffect
            
        Case "Count image colors"
            MenuCountColors
            
        Case "Rainbow"
            MenuRainbow
            
        Case "Vibrate"
            MenuVibrate
            
        Case "Despeckle"
            FormDespeckle.QuickDespeckle
            
        Case "Custom despeckle"
            If ShowDialog Then
                FormDespeckle.Show vbModal, FormMain
            Else
                FormDespeckle.Despeckle cParams.GetLong(1)
            End If
            
        Case "Sepia"
            MenuSepia
            
        Case "Thermograph (heat map)"
            MenuHeatMap
            
        Case "Comic book"
            MenuComicBook
            
        Case "Add film grain"
            If ShowDialog Then
                FormFilmGrain.Show vbModal, FormMain
            Else
                FormFilmGrain.AddFilmGrain cParams.GetDouble(1), cParams.GetLong(2)
            End If
            
        Case "Film noir"
            MenuFilmNoir
            
        Case "Vignetting"
            If ShowDialog Then
                FormVignette.Show vbModal, FormMain
            Else
                FormVignette.ApplyVignette cParams.GetDouble(1), cParams.GetDouble(2), cParams.GetDouble(3), cParams.GetBool(4), cParams.GetLong(5)
            End If
            
        Case "Median"
            If ShowDialog Then
                FormMedian.showMedianDialog 50
            Else
                FormMedian.ApplyMedianFilter cParams.GetLong(1), cParams.GetDouble(2)
            End If
            
        Case "Modern art"
            If ShowDialog Then
                FormModernArt.Show vbModal, FormMain
            Else
                FormModernArt.ApplyModernArt cParams.GetLong(1)
            End If
            
        Case "Photo filter"
            If ShowDialog Then
                FormPhotoFilters.Show vbModal, FormMain
            Else
                FormPhotoFilters.ApplyPhotoFilter cParams.GetLong(1), cParams.GetDouble(2), cParams.GetBool(3)
            End If
        
        
        'SPECIAL OPERATIONS
        Case "Fade last effect"
            MenuFadeLastEffect
            
            
        'DEBUG FAILSAFE
        ' This function should never be passed a process ID it can't parse, but if that happens, ask the user to report the unparsed ID
        Case Else
            If Len(processID) > 0 Then pdMsgBox "Unknown processor request submitted: %1" & vbCrLf & vbCrLf & "Please report this bug via the Help -> Submit Bug Report menu.", vbCritical + vbOKOnly + vbApplicationModal, "Processor Error", processID
        
    End Select
    
    'If the user wants us to time this action, display the results now
    If createUndo Then
        If DISPLAY_TIMINGS Then Message "Time taken: " & Format$(Timer - m_ProcessingTime, "#0.####") & " seconds"
    End If
    
    'Restore the mouse pointer to its default value.
    ' (NOTE: if we are in the midst of a batch conversion, leave the cursor on "busy".  The batch function will restore the cursor when done.)
    If MacroStatus <> MacroBATCH Then Screen.MousePointer = vbDefault
    
    'If the histogram form is visible and images are loaded, redraw the histogram
    If FormHistogram.Visible Then
        If NumOfWindows > 0 Then
            FormHistogram.TallyHistogramValues
            FormHistogram.DrawHistogram
        Else
            'If the histogram is visible but no images are open, unload the histogram
            Unload FormHistogram
        End If
    End If
    
    'If the image has been modified and we are not performing a batch conversion (disabled to save speed!), redraw the form icon to match.
    If createUndo And (MacroStatus <> MacroBATCH) Then CreateCustomFormIcon FormMain.ActiveForm
    
    'Unlock the main form
    FormMain.Enabled = True
    
    'If a filter or tool was just used, return focus to the active form.  This will make it "flash" to catch the user's attention.
    If createUndo Then
        If NumOfWindows > 0 Then FormMain.ActiveForm.SetFocus
    End If
        
    'Also, re-enable drag and drop operations
    If createUndo >= 101 Then
        g_AllowDragAndDrop = True
        FormMain.OLEDropMode = 1
    End If
    
    'Mark the processor as ready
    Processing = False
    
    Exit Sub


'MAIN PHOTODEMON ERROR HANDLER STARTS HERE

MainErrHandler:

    'Reset the mouse pointer and access to the main form
    Screen.MousePointer = vbDefault
    FormMain.Enabled = True

    'We'll use this string to hold additional error data
    Dim AddInfo As String
    
    'This variable stores the message box type
    Dim mType As VbMsgBoxStyle
    
    'Tracks the user input from the message box
    Dim msgReturn As VbMsgBoxResult
    
    'Ignore errors that aren't actually errors
    If Err.Number = 0 Then Exit Sub
    
    'Object was unloaded before it could be shown - this is intentional, so ignore the error
    If Err.Number = 364 Then Exit Sub
        
    'Out of memory error
    If Err.Number = 480 Or Err.Number = 7 Then
        AddInfo = g_Language.TranslateMessage("There is not enough memory available to continue this operation.  Please free up system memory (RAM) by shutting down unneeded programs - especially your web browser, if it is open - then try the action again.")
        Message "Out of memory.  Function cancelled."
        mType = vbExclamation + vbOKOnly + vbApplicationModal
    
    'Invalid picture error
    ElseIf Err.Number = 481 Then
        AddInfo = g_Language.TranslateMessage("Unfortunately, this image file appears to be invalid.  This can happen if a file does not contain image data, or if it contains image data in an unsupported format." & vbCrLf & vbCrLf & "- If you downloaded this image from the Internet, the download may have terminated prematurely.  Please try downloading the image again." & vbCrLf & vbCrLf & "- If this image file came from a digital camera, scanner, or other image editing program, it's possible that PhotoDemon simply doesn't understand this particular file format.  Please save the image in a generic format (such as JPEG or PNG), then reload it.")
        Message "Invalid image.  Image load cancelled."
        mType = vbExclamation + vbOKOnly + vbApplicationModal
    
        'Since we know about this error, there's no need to display the extended box.  Display a smaller one, then exit.
        pdMsgBox AddInfo, mType, "Invalid image file"
        
        'On an invalid picture load, there will be a blank form that needs to be dealt with.
        pdImages(CurrentImage).deactivateImage
        Unload FormMain.ActiveForm
        Exit Sub
    
    'File not found error
    ElseIf Err.Number = 53 Then
        AddInfo = g_Language.TranslateMessage("The specified file could not be located.  If it was located on removable media, please re-insert the proper floppy disk, CD, or portable drive.  If the file is not located on portable media, make sure that:" & vbCrLf & "1) the file hasn't been deleted, and..." & vbCrLf & "2) the file location provided to PhotoDemon is correct.")
        Message "File not found."
        mType = vbExclamation + vbOKOnly + vbApplicationModal
        
    'Unknown error
    Else
        AddInfo = g_Language.TranslateMessage("PhotoDemon cannot locate additional information for this error.  That probably means this error is a bug, and it needs to be fixed!" & vbCrLf & vbCrLf & "Would you like to submit a bug report?  (It takes less than one minute, and it helps everyone who uses the software.)")
        mType = vbCritical + vbYesNo + vbApplicationModal
        Message "Unknown error."
    End If
    
    'Create the message box to return the error information
    msgReturn = pdMsgBox("PhotoDemon has experienced an error.  Details on the problem include:" & vbCrLf & vbCrLf & "Error number %1" & vbCrLf & "Description: %2" & vbCrLf & vbCrLf & "%3", mType, "PhotoDemon Error Handler", Err.Number, Err.Description, AddInfo)
    
    'If the message box return value is "Yes", the user has opted to file a bug report.
    If msgReturn = vbYes Then
    
        'GitHub requires a login for submitting Issues; check for that first
        Dim secondaryReturn As VbMsgBoxResult
    
        secondaryReturn = pdMsgBox("Thank you for submitting a bug report.  To make sure your bug is addressed as quickly as possible, PhotoDemon needs you to answer one more question." & vbCrLf & vbCrLf & "Do you have a GitHub account? (If you have no idea what this means, answer ""No"".)", vbQuestion + vbApplicationModal + vbYesNo, "Thanks for making PhotoDemon better")
    
        'If they have a GitHub account, let them submit the bug there.  Otherwise, send them to the tannerhelland.com contact form
        If secondaryReturn = vbYes Then
            'Shell a browser window with the GitHub issue report form
            OpenURL "https://github.com/tannerhelland/PhotoDemon/issues/new"
            
            'Display one final message box with additional instructions
            pdMsgBox "PhotoDemon has automatically opened a GitHub bug report webpage for you.  In the Title box, please enter the following error number with a short description of the problem: " & vbCrLf & "%1" & vbCrLf & vbCrLf & "Any additional details you can provide in the large text box, including the steps that led up to this error, will help it get fixed as quickly as possible." & vbCrLf & vbCrLf & "When finished, click the Submit New Issue button.  Thank you!", vbInformation + vbApplicationModal + vbOKOnly, "GitHub bug report instructions", Err.Number
            
        Else
            'Shell a browser window with the tannerhelland.com PhotoDemon contact form
            OpenURL "http://www.tannerhelland.com/photodemon-contact/"
            
            'Display one final message box with additional instructions
            pdMsgBox "PhotoDemon has automatically opened a bug report webpage for you.  In the Additional Details box, please describe the steps that led to this error." & vbCrLf & vbCrLf & "In the bottom box of that page, please enter the following error number: " & vbCrLf & "%1" & vbCrLf & vbCrLf & "When finished, click the Submit button.  Thank you!", vbInformation + vbApplicationModal + vbOKOnly, "Bug report instructions", Err.Number
            
        End If
    
    End If
        
End Sub
